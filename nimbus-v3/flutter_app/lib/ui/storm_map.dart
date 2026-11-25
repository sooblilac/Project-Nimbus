import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../data/philippine_location.dart';
import '../lgu/lgu_api.dart';
import 'offline_map_plan.dart';
import 'theme.dart';

class StormMap extends StatefulWidget {
  const StormMap({
    super.key,
    required this.location,
    required this.outline,
    required this.floodReported,
    this.mapPins = const [],
    this.onMapTap,
    this.onPinTapped,
    this.pinPlacementMode = false,
    this.attributionBottomInset = 8,
    this.errorOverlayLeftInset = 12,
  });

  final PhilippineLocation location;
  final PhilippineOutline outline;
  final bool floodReported;
  final List<MapPinUpdate> mapPins;
  final void Function(double latitude, double longitude)? onMapTap;
  final ValueChanged<MapPinUpdate>? onPinTapped;
  final bool pinPlacementMode;
  final double attributionBottomInset;
  final double errorOverlayLeftInset;

  @override
  State<StormMap> createState() => _StormMapState();
}

class _StormMapState extends State<StormMap> {
  static const _styleUrl = 'https://tiles.openfreemap.org/styles/liberty';
  static const _userAgent = 'Nimbus/3.0 (Android; offline map client)';

  ml.MapLibreMapController? _controller;
  ml.Circle? _locationMarker;
  final _fallbackTransformationController = TransformationController();
  final Map<ml.Circle, MapPinUpdate> _pinMarkers = {};
  Future<void> _pinSyncQueue = Future<void>.value();
  int _pinSyncId = 0;
  List<ml.OfflineRegion> _regions = [];
  bool _styleLoaded = false;
  bool _mapUnavailable = false;
  bool _offlineAvailable = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  int _downloadedBytes = 0;
  String _activePackLabel = '';
  String? _offlineError;
  Timer? _styleLoadTimer;

  @override
  void initState() {
    super.initState();
    _startStyleLoadTimer();
    unawaited(_configureOfflineMaps());
  }

  @override
  void dispose() {
    _styleLoadTimer?.cancel();
    _fallbackTransformationController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant StormMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location.code != widget.location.code) {
      unawaited(_focusLocation());
    }
    if (oldWidget.location.code != widget.location.code ||
        oldWidget.floodReported != widget.floodReported) {
      unawaited(_syncLocationMarker());
    }
    if (oldWidget.location.code != widget.location.code ||
        oldWidget.mapPins != widget.mapPins) {
      unawaited(_syncPins());
    }
  }

  Future<void> _configureOfflineMaps() async {
    final isMobilePlatform =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (!isMobilePlatform) {
      if (mounted) {
        setState(() {
          _offlineError =
              'Offline map downloads are available on Android and iOS.';
        });
      }
      return;
    }

    try {
      await ml.setHttpHeaders({'User-Agent': _userAgent});
      await ml.setOfflineTileCountLimit(maxOfflineMapTiles);
      await ml.setOfflineMaxConcurrentRequests(
        maxRequests: defaultTargetPlatform == TargetPlatform.android ? 4 : null,
        maxRequestsPerHost: 4,
      );
      final regions = await ml.getListOfRegions();
      if (!mounted) return;
      setState(() {
        _regions = regions;
        _offlineAvailable = true;
      });
      unawaited(_focusLocation());
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _offlineError =
            'Offline map setup failed: ${error.message ?? error.code}';
      });
    }
  }

  void _onMapCreated(ml.MapLibreMapController controller) {
    _controller = controller;
    controller.onCircleTapped.add(_onCircleTapped);
  }

  void _onCircleTapped(ml.Circle circle) {
    final pin = _pinMarkers[circle];
    if (pin != null) widget.onPinTapped?.call(pin);
  }

  void _onMapClick(ml.LatLng coordinates) {
    if (!widget.pinPlacementMode) return;
    widget.onMapTap?.call(coordinates.latitude, coordinates.longitude);
  }

  void _onFallbackMapTap(Offset viewportPosition, Size size) {
    final inverseTransform =
        _fallbackTransformationController.value.clone()..invert();
    final mapPosition = MatrixUtils.transformPoint(
      inverseTransform,
      viewportPosition,
    );
    if (widget.pinPlacementMode) {
      final bounds = widget.outline.bounds;
      final scale = math.min(
        (size.width - 32) / bounds.width,
        (size.height - 32) / bounds.height,
      );
      if (scale <= 0) return;
      final mapWidth = bounds.width * scale;
      final mapHeight = bounds.height * scale;
      final origin = Offset(
        (size.width - mapWidth) / 2,
        (size.height - mapHeight) / 2,
      );
      final longitude = bounds.left + (mapPosition.dx - origin.dx) / scale;
      final latitude = bounds.bottom - (mapPosition.dy - origin.dy) / scale;
      if (!bounds.contains(Offset(longitude, latitude))) return;
      widget.onMapTap?.call(latitude, longitude);
      return;
    }

    for (final pin in widget.mapPins) {
      final pinPosition = _projectFallbackCoordinate(
        widget.outline,
        size,
        pin.longitude,
        pin.latitude,
      );
      if ((mapPosition - pinPosition).distance <= 18) {
        widget.onPinTapped?.call(pin);
        return;
      }
    }
  }

  void _onStyleLoaded() {
    _styleLoadTimer?.cancel();
    _styleLoaded = true;
    if (_mapUnavailable && mounted) {
      setState(() => _mapUnavailable = false);
    }
    _locationMarker = null;
    _pinMarkers.clear();
    unawaited(_focusLocation());
    unawaited(_syncLocationMarker());
    unawaited(_syncPins());
  }

  void _startStyleLoadTimer() {
    _styleLoadTimer?.cancel();
    _styleLoadTimer = Timer(const Duration(seconds: 12), () {
      if (mounted && !_styleLoaded) {
        setState(() => _mapUnavailable = true);
      }
    });
  }

  Future<void> _syncLocationMarker() async {
    final controller = _controller;
    if (!_styleLoaded || controller == null) return;

    final color =
        widget.floodReported ? NimbusColors.danger : NimbusColors.primary;
    final options = ml.CircleOptions(
      geometry: ml.LatLng(widget.location.latitude, widget.location.longitude),
      circleRadius: 8,
      circleColor: _hexColor(color),
      circleStrokeColor: _hexColor(context.nimbusPalette.surface),
      circleStrokeWidth: 3,
    );
    try {
      final marker = _locationMarker;
      if (marker == null) {
        _locationMarker = await controller.addCircle(options);
      } else {
        await controller.updateCircle(marker, options);
      }
    } on PlatformException catch (error) {
      _showMessage(
        'Could not update the map marker: ${error.message ?? error.code}',
      );
    }
  }

  Future<void> _syncPins() {
    final controller = _controller;
    if (!_styleLoaded || controller == null) return Future<void>.value();
    final syncId = ++_pinSyncId;
    final surfaceColor = context.nimbusPalette.surface;
    final sync = _pinSyncQueue.then((_) async {
      if (syncId != _pinSyncId) return;
      try {
        for (final marker in _pinMarkers.keys.toList()) {
          await controller.removeCircle(marker);
        }
        _pinMarkers.clear();
        if (syncId != _pinSyncId) return;
        for (final pin in widget.mapPins) {
          final marker = await controller.addCircle(
            ml.CircleOptions(
              geometry: ml.LatLng(pin.latitude, pin.longitude),
              circleRadius: 9 + pin.intensity / 20,
              circleColor: _hexColor(_pinColorFor(pin)),
              circleStrokeColor: _hexColor(surfaceColor),
              circleStrokeWidth: 3,
            ),
          );
          if (syncId != _pinSyncId) {
            await controller.removeCircle(marker);
            return;
          }
          _pinMarkers[marker] = pin;
        }
      } on PlatformException catch (error) {
        _showMessage(
          'Could not update map pins: ${error.message ?? error.code}',
        );
      }
    });
    _pinSyncQueue = sync;
    return sync;
  }

  double get _locationZoom {
    if (_hasPack('detail-${widget.location.code}')) return 13;
    if (_hasPack('philippines-overview')) return 5.2;
    return 13;
  }

  Future<void> _focusLocation() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngZoom(
        ml.LatLng(widget.location.latitude, widget.location.longitude),
        _locationZoom,
      ),
      duration: const Duration(milliseconds: 450),
    );
  }

  Future<void> _refreshOfflineRegions() async {
    final regions = await ml.getListOfRegions();
    if (mounted) setState(() => _regions = regions);
  }

  bool _hasPack(String packId) =>
      _regions.any((region) => region.metadata['packId'] == packId);

  Future<void> _openOfflineMaps() async {
    if (!_offlineAvailable) {
      _showMessage(_offlineError ?? 'Offline map downloads are not available.');
      return;
    }
    try {
      await _refreshOfflineRegions();
      unawaited(_focusLocation());
    } on PlatformException catch (error) {
      _showMessage('Could not load saved maps: ${error.message ?? error.code}');
      return;
    }
    if (!mounted) return;

    final overview = philippinesOverviewBounds(widget.outline);
    final detail = locationDetailBounds(widget.location);
    final overviewTiles = estimateOfflineTileCount(
      overview,
      minZoom: 3,
      maxZoom: 7,
    );
    final detailTiles = estimateOfflineTileCount(
      detail,
      minZoom: 9,
      maxZoom: 15,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Offline maps',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Download map areas while online, then pan and zoom without a connection. '
                      'Each pack is limited to 3,000 tiles and 45 MB.',
                    ),
                    const SizedBox(height: 12),
                    _downloadOption(
                      sheetContext,
                      packId: 'philippines-overview',
                      label: 'Philippines overview',
                      bounds: overview,
                      minZoom: 3,
                      maxZoom: 7,
                      estimatedTiles: overviewTiles,
                    ),
                    _downloadOption(
                      sheetContext,
                      packId: 'detail-${widget.location.code}',
                      label: 'Detailed map near ${widget.location.name}',
                      bounds: detail,
                      minZoom: 9,
                      maxZoom: 15,
                      estimatedTiles: detailTiles,
                    ),
                    if (_regions.isNotEmpty) ...[
                      const Divider(),
                      Text(
                        'Saved areas',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      for (final region in _regions)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.map_outlined),
                          title: Text(_regionLabel(region)),
                          subtitle: const Text('Stored on this device'),
                          trailing: IconButton(
                            tooltip: 'Delete offline map',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              Navigator.of(sheetContext).pop();
                              unawaited(_confirmDeleteRegion(region));
                            },
                          ),
                        ),
                    ],
                    const Divider(),
                    const Text(
                      'Map data: OpenFreeMap, OpenMapTiles and '
                      '© OpenStreetMap contributors.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  Widget _downloadOption(
    BuildContext sheetContext, {
    required String packId,
    required String label,
    required ml.LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    required int estimatedTiles,
  }) {
    final saved = _hasPack(packId);
    final exceedsLimit = estimatedTiles > maxOfflineMapTiles;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        saved ? Icons.download_done : Icons.cloud_download_outlined,
      ),
      title: Text(label),
      subtitle: Text(
        saved
            ? 'Saved for offline use'
            : 'About $estimatedTiles tiles · zoom $minZoom–$maxZoom',
      ),
      trailing:
          saved
              ? const Icon(Icons.check_circle, color: NimbusColors.ok)
              : const Icon(Icons.download_outlined),
      onTap:
          saved || exceedsLimit || _downloading
              ? null
              : () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  _downloadPack(
                    packId: packId,
                    label: label,
                    bounds: bounds,
                    minZoom: minZoom,
                    maxZoom: maxZoom,
                    estimatedTiles: estimatedTiles,
                  ),
                );
              },
    );
  }

  Future<void> _downloadPack({
    required String packId,
    required String label,
    required ml.LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    required int estimatedTiles,
  }) async {
    if (_downloading) return;
    if (estimatedTiles > maxOfflineMapTiles) {
      _showMessage(
        'This map area exceeds the $maxOfflineMapTiles-tile download limit.',
      );
      return;
    }

    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _downloadedBytes = 0;
      _activePackLabel = label;
    });

    final terminalEvent = Completer<ml.DownloadRegionStatus>();
    final sizeLimitReached = Completer<void>();
    final downloadStalled = Completer<void>();
    Timer? stallTimer;
    void resetStallTimer() {
      stallTimer?.cancel();
      stallTimer = Timer(const Duration(seconds: 30), () {
        if (!downloadStalled.isCompleted) downloadStalled.complete();
      });
    }

    resetStallTimer();
    try {
      final region = await ml.downloadOfflineRegion(
        ml.OfflineRegionDefinition(
          bounds: bounds,
          mapStyleUrl: _styleUrl,
          minZoom: minZoom.toDouble(),
          maxZoom: maxZoom.toDouble(),
        ),
        metadata: {
          'packId': packId,
          'label': label,
          'source': 'OpenFreeMap / OpenMapTiles / OpenStreetMap',
          'estimatedTiles': estimatedTiles,
        },
        onEvent: (event) {
          if (event is ml.InProgress) {
            resetStallTimer();
            if (event.completedResourceSize >= maxOfflineMapDownloadBytes &&
                !sizeLimitReached.isCompleted) {
              sizeLimitReached.complete();
            }
            if (mounted) {
              setState(() {
                _downloadProgress = event.progress.clamp(0, 1).toDouble();
                _downloadedBytes = event.completedResourceSize;
              });
            }
          } else if ((event is ml.Success || event is ml.Error) &&
              !terminalEvent.isCompleted) {
            terminalEvent.complete(event);
          }
        },
      );

      final result = await Future.any<ml.DownloadRegionStatus?>([
        terminalEvent.future,
        sizeLimitReached.future.then<ml.DownloadRegionStatus?>((_) => null),
        downloadStalled.future.then<ml.DownloadRegionStatus?>((_) => null),
      ]);
      if (sizeLimitReached.isCompleted || result == null) {
        await ml.pauseOfflineRegionDownload(region.id);
        await ml.deleteOfflineRegion(region.id);
        await ml.clearAmbientCache();
        throw StateError(
          sizeLimitReached.isCompleted
              ? 'The map exceeded 45 MB, so the partial download was removed.'
              : 'Map download stalled. Check the phone connection and try again.',
        );
      }
      if (result is ml.Error) {
        await ml.deleteOfflineRegion(region.id);
        await ml.clearAmbientCache();
        throw result.cause;
      }

      await _refreshOfflineRegions();
      if (await _reloadMapStyle()) {
        _showMessage('$label is ready for offline use.');
      }
    } on PlatformException catch (error) {
      _showMessage('Map download failed: ${error.message ?? error.code}');
    } on StateError catch (error) {
      _showMessage(error.message.toString());
    } finally {
      stallTimer?.cancel();
      if (mounted) {
        setState(() {
          _downloading = false;
          _downloadProgress = 0;
          _activePackLabel = '';
        });
      }
    }
  }

  Future<void> _confirmDeleteRegion(ml.OfflineRegion region) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Delete offline map?'),
            content: Text('Remove ${_regionLabel(region)} from this device?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (shouldDelete != true) return;
    try {
      await ml.deleteOfflineRegion(region.id);
      await ml.clearAmbientCache();
      await _refreshOfflineRegions();
      if (await _reloadMapStyle()) {
        _showMessage('${_regionLabel(region)} was deleted.');
      }
    } on PlatformException catch (error) {
      _showMessage('Could not delete the map: ${error.message ?? error.code}');
    }
  }

  String _regionLabel(ml.OfflineRegion region) {
    final label = region.metadata['label'];
    return label is String ? label : 'Saved map area';
  }

  Future<bool> _reloadMapStyle() async {
    final controller = _controller;
    if (controller == null) return true;
    _styleLoaded = false;
    _locationMarker = null;
    _pinSyncId++;
    _pinMarkers.clear();
    if (mounted) setState(() => _mapUnavailable = false);
    _startStyleLoadTimer();
    try {
      await controller.setStyle(_styleUrl);
      return true;
    } on PlatformException catch (error) {
      _showMessage(
        'Map saved, but the display could not refresh: '
        '${error.message ?? error.code}',
      );
      return false;
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _hexColor(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Interactive map of the Philippines. '
        '${widget.location.searchLabel} selected.',
    child: Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: context.nimbusPalette.mapWater,
          child: ml.MapLibreMap(
            styleString: _styleUrl,
            initialCameraPosition: ml.CameraPosition(
              target: ml.LatLng(
                widget.location.latitude,
                widget.location.longitude,
              ),
              zoom: _locationZoom,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onMapClick: (_, coordinates) => _onMapClick(coordinates),
            gestureRecognizers: {
              Factory<OneSequenceGestureRecognizer>(
                () => EagerGestureRecognizer(),
              ),
            },
            scrollGesturesEnabled: true,
            zoomGesturesEnabled: true,
            doubleClickZoomEnabled: true,
            dragEnabled: true,
            annotationOrder: const [ml.AnnotationType.circle],
            logoEnabled: true,
            scaleControlEnabled: true,
            translucentTextureSurface: true,
          ),
        ),
        if (_mapUnavailable)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return Stack(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp:
                          widget.pinPlacementMode || widget.mapPins.isNotEmpty
                              ? (details) =>
                                  _onFallbackMapTap(details.localPosition, size)
                              : null,
                      child: InteractiveViewer(
                        transformationController:
                            _fallbackTransformationController,
                        minScale: 1,
                        maxScale: 5,
                        boundaryMargin: const EdgeInsets.all(80),
                        child: CustomPaint(
                          size: size,
                          painter: _PhilippinesOutlinePainter(
                            outline: widget.outline,
                            location: widget.location,
                            mapPins: widget.mapPins,
                            palette: context.nimbusPalette,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: widget.errorOverlayLeftInset,
                      right: 12,
                      bottom: widget.attributionBottomInset + 52,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Street map tiles for ${widget.location.name} are unavailable. '
                                  'Check your connection, then download this area.',
                                ),
                              ),
                              IconButton(
                                tooltip: 'Retry map',
                                onPressed: () => unawaited(_reloadMapStyle()),
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        Positioned(
          right: 12,
          top: 144,
          child: FloatingActionButton.small(
            heroTag: 'offline-map-download',
            tooltip: 'Manage offline maps',
            onPressed: _openOfflineMaps,
            child: const Icon(Icons.download_for_offline_outlined),
          ),
        ),
        if (_downloading)
          Positioned(
            left: 12,
            right: 12,
            top: 144,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Downloading $_activePackLabel'),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: _downloadProgress),
                    const SizedBox(height: 4),
                    Text(
                      '${(_downloadProgress * 100).round()}% · '
                      '${(_downloadedBytes / 1000000).toStringAsFixed(1)} MB',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          left: 12,
          bottom: widget.attributionBottomInset,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.nimbusPalette.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Text(
                '© OpenFreeMap · OpenMapTiles · OpenStreetMap',
                style: TextStyle(
                  fontSize: 10,
                  color: context.nimbusPalette.text,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

Color _pinColorFor(MapPinUpdate pin) {
  final Color base;
  final Color strong;
  switch (pin.category) {
    case 'flood':
      base = const Color(0xFFFFB74D);
      strong = const Color(0xFFB71C1C);
    case 'evacuation':
      base = const Color(0xFF81C784);
      strong = const Color(0xFF1B5E20);
    default:
      base = const Color(0xFFFFD54F);
      strong = const Color(0xFF8E0000);
  }
  return Color.lerp(base, strong, pin.intensity / 100)!;
}

Offset _projectFallbackCoordinate(
  PhilippineOutline outline,
  Size size,
  double longitude,
  double latitude,
) {
  final bounds = outline.bounds;
  final scale = math.min(
    (size.width - 32) / bounds.width,
    (size.height - 32) / bounds.height,
  );
  final mapWidth = bounds.width * scale;
  final mapHeight = bounds.height * scale;
  final origin = Offset(
    (size.width - mapWidth) / 2,
    (size.height - mapHeight) / 2,
  );
  return Offset(
    origin.dx + (longitude - bounds.left) * scale,
    origin.dy + (bounds.bottom - latitude) * scale,
  );
}

class _PhilippinesOutlinePainter extends CustomPainter {
  const _PhilippinesOutlinePainter({
    required this.outline,
    required this.location,
    required this.mapPins,
    required this.palette,
  });

  final PhilippineOutline outline;
  final PhilippineLocation location;
  final List<MapPinUpdate> mapPins;
  final NimbusPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = outline.bounds;
    final scale = math.min(
      (size.width - 32) / bounds.width,
      (size.height - 32) / bounds.height,
    );
    final mapWidth = bounds.width * scale;
    final mapHeight = bounds.height * scale;
    final origin = Offset(
      (size.width - mapWidth) / 2,
      (size.height - mapHeight) / 2,
    );
    Offset project(double longitude, double latitude) => Offset(
      origin.dx + (longitude - bounds.left) * scale,
      origin.dy + (bounds.bottom - latitude) * scale,
    );

    final fill =
        Paint()
          ..color = const Color(0xFFB8D9C0)
          ..style = PaintingStyle.fill;
    final stroke =
        Paint()
          ..color = const Color(0xFF426A57)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4;
    for (final island in outline.islands) {
      final path = Path();
      for (var index = 0; index < island.length; index++) {
        final point = island[index];
        final projected = project(point.dx, point.dy);
        if (index == 0) {
          path.moveTo(projected.dx, projected.dy);
        } else {
          path.lineTo(projected.dx, projected.dy);
        }
      }
      path.close();
      canvas
        ..drawPath(path, fill)
        ..drawPath(path, stroke);
    }

    for (final pin in mapPins) {
      final marker = project(pin.longitude, pin.latitude);
      final radius = 5 + pin.intensity / 20;
      canvas
        ..drawCircle(marker, radius + 2, Paint()..color = palette.surface)
        ..drawCircle(marker, radius, Paint()..color = _pinColorFor(pin));
    }

    final marker = project(location.longitude, location.latitude);
    canvas
      ..drawCircle(marker, 9, Paint()..color = palette.surface)
      ..drawCircle(marker, 6, Paint()..color = NimbusColors.danger);
  }

  @override
  bool shouldRepaint(_PhilippinesOutlinePainter oldDelegate) =>
      oldDelegate.outline != outline ||
      oldDelegate.location != location ||
      oldDelegate.mapPins != mapPins ||
      oldDelegate.palette != palette;
}
