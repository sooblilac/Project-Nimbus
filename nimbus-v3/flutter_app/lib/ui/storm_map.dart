import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../data/philippine_location.dart';
import '../lgu/lgu_api.dart';
import 'offline_map_plan.dart';
import 'theme.dart';

/// Bundled UP NOAH hazard maps, keyed by PSGC town code then hazard.
/// See assets/data/hazards/ATTRIBUTION.md for source and license (ODbL).
const _hazardDir = 'assets/data/hazards';
const _hazardAssets = <String, Map<String, String>>{
  '0401005000': {
    'flood': '$_hazardDir/noah_flood_100yr_0401005000.geojson',
    'landslide': '$_hazardDir/noah_landslide_0401005000.geojson',
    'surge': '$_hazardDir/noah_surge_0401005000.geojson',
  },
  '0401019000': {
    'flood': '$_hazardDir/noah_flood_0401019000.geojson',
    'landslide': '$_hazardDir/noah_landslide_0401019000.geojson',
    'surge': '$_hazardDir/noah_surge_0401019000.geojson',
  },
  '0200901000': {
    'flood': '$_hazardDir/noah_flood_0200901000.geojson',
    'landslide': '$_hazardDir/noah_landslide_0200901000.geojson',
    'surge': '$_hazardDir/noah_surge_0200901000.geojson',
  },
};

/// Menu label, legend title, legend footnote, icon.
const _hazardInfo = <String, (String, String, String, IconData)>{
  'flood': (
    'Flood',
    'Flood-prone in heavy rain',
    'UP NOAH · 100-yr rain · not live',
    Icons.flood_outlined,
  ),
  'landslide': (
    'Landslide',
    'Landslide-prone areas',
    'UP NOAH · not live',
    Icons.landslide_outlined,
  ),
  'surge': (
    'Storm surge',
    'Storm surge, worst case',
    'UP NOAH · surge advisory 4 · not live',
    Icons.tsunami_outlined,
  ),
};
const _hazardSourceId = 'noah-flood-hazard';
const _hazardLayerId = 'noah-flood-hazard-fill';
const _hazardLow = Color(0xFFF5D76E);
const _hazardMedium = Color(0xFFF0A030);
const _hazardHigh = NimbusColors.danger;

class StormMap extends StatefulWidget {
  const StormMap({
    super.key,
    required this.location,
    this.focusRequest = 0,
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

  /// Bump to fly to [location] again, even if it didn't change.
  final int focusRequest;
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
  static const _darkStyleUrl = 'https://tiles.openfreemap.org/styles/dark';

  /// Dark map in dark mode. Offline packs are saved with the light style, so if the
  /// dark style can't load (offline, never cached) we fall back to light.
  bool _darkStyleFailed = false;
  String? _appliedStyleUrl;
  String get _activeStyleUrl =>
      Theme.of(context).brightness == Brightness.dark && !_darkStyleFailed
          ? _darkStyleUrl
          : _styleUrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = _activeStyleUrl;
    if (_appliedStyleUrl != null &&
        next != _appliedStyleUrl &&
        _controller != null) {
      _appliedStyleUrl = next;
      unawaited(_reloadMapStyle());
    }
  }

  static const _userAgent = 'Nimbus/3.0 (Android; offline map client)';

  ml.MapLibreMapController? _controller;
  ml.Circle? _locationMarker;
  final _fallbackTransformationController = TransformationController();
  final Map<ml.Circle, MapPinUpdate> _pinMarkers = {};
  final Map<ml.Symbol, MapPinUpdate> _pinSymbols = {};
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
  MapPinUpdate? _selectedPin;
  Offset? _selectedPinScreenPoint;
  double _cameraZoom = 5.2;
  bool _showPinLabels = true;
  bool _pinLabelUpdateInFlight = false;
  bool _pinLabelUpdatePending = false;
  final Map<String, Offset> _pinLabelPositions = {};

  /// Hazard map shown: 'flood', 'landslide', 'surge' or null for none.
  String? _hazard;
  bool _toolsOpen = false;
  String? _hazardOnMapCode;
  Future<void> _hazardQueue = Future<void>.value();

  Map<String, String>? get _townHazards => _hazardAssets[widget.location.code];
  String? get _hazardAsset => _hazard == null ? null : _townHazards?[_hazard];

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
    if (oldWidget.location.code != widget.location.code ||
        oldWidget.focusRequest != widget.focusRequest) {
      unawaited(_focusLocation());
      unawaited(_syncFloodHazard());
    }
    if (oldWidget.location.code != widget.location.code ||
        oldWidget.floodReported != widget.floodReported) {
      unawaited(_syncLocationMarker());
    }
    if (oldWidget.location.code != widget.location.code ||
        oldWidget.mapPins != widget.mapPins) {
      unawaited(_syncPins());
      unawaited(_updatePinLabelPositions());
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
    _cameraZoom = _locationZoom;
    controller.onCircleTapped.add(_onCircleTapped);
    controller.onSymbolTapped.add((symbol) {
      final pin = _pinSymbols[symbol];
      if (pin != null) _onPinTapped(pin);
    });
  }

  void _onCircleTapped(ml.Circle circle) {
    final pin = _pinMarkers[circle];
    if (pin != null) _onPinTapped(pin);
  }

  void _onPinTapped(MapPinUpdate pin) {
    {
      setState(() => _selectedPin = pin);
      unawaited(_updateSelectedPinPosition());
      widget.onPinTapped?.call(pin);
    }
  }

  Future<void> _updateSelectedPinPosition() async {
    final controller = _controller;
    final pin = _selectedPin;
    if (!mounted || controller == null || pin == null || _cameraZoom < 10.5) {
      if (mounted && _selectedPinScreenPoint != null) {
        setState(() => _selectedPinScreenPoint = null);
      }
      return;
    }
    try {
      final point = await controller.toScreenLocation(
        ml.LatLng(pin.latitude, pin.longitude),
      );
      if (!mounted || _selectedPin != pin) return;
      setState(() => _selectedPinScreenPoint = _toLogicalOffset(point));
    } catch (_) {
      if (mounted) setState(() => _selectedPinScreenPoint = null);
    }
  }

  void _onCameraMove(ml.CameraPosition position) {
    _cameraZoom = position.zoom;
    // Chasing the camera with platform calls every frame makes zoom/pan stutter.
    // Hide the overlays while moving; _onCameraIdle puts them back in one pass.
    if (_selectedPinScreenPoint != null || _pinLabelPositions.isNotEmpty) {
      setState(() {
        _selectedPinScreenPoint = null;
        _pinLabelPositions.clear();
      });
    }
  }

  void _onCameraIdle() {
    if (_toolsOpen && mounted) setState(() {}); // keep the zoom slider in step
    unawaited(_updateSelectedPinPosition());
    unawaited(_updatePinLabelPositions());
  }

  Future<void> _showPinBubble(MapPinUpdate pin) async {
    widget.onPinTapped?.call(pin);
    if (_cameraZoom < 11) {
      if (mounted)
        setState(() {
          _selectedPin = null;
          _selectedPinScreenPoint = null;
        });
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    try {
      final point = await controller.toScreenLocation(
        ml.LatLng(pin.latitude, pin.longitude),
      );
      if (!mounted) return;
      setState(() {
        _selectedPin = pin;
        _selectedPinScreenPoint = _toLogicalOffset(point);
      });
    } catch (_) {}
  }

  void _onMapClick(ml.LatLng coordinates) {
    if (widget.pinPlacementMode) {
      widget.onMapTap?.call(coordinates.latitude, coordinates.longitude);
      return;
    }

    MapPinUpdate? nearest;
    var nearestDistance = double.infinity;
    for (final pin in widget.mapPins) {
      final latitudeDistance = coordinates.latitude - pin.latitude;
      final longitudeDistance =
          (coordinates.longitude - pin.longitude) *
          math.cos(pin.latitude * math.pi / 180);
      final distance = math.sqrt(
        latitudeDistance * latitudeDistance +
            longitudeDistance * longitudeDistance,
      );
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = pin;
      }
    }
    if (nearest != null && nearestDistance < 0.008) {
      unawaited(_showPinBubble(nearest));
    }
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
        unawaited(_showPinBubble(pin));
        return;
      }
    }
  }

  void _onStyleLoaded() {
    _styleLoadTimer?.cancel();
    _cameraZoom = _locationZoom;
    _styleLoaded = true;
    if (_mapUnavailable && mounted) {
      setState(() => _mapUnavailable = false);
    }
    _locationMarker = null;
    _pinMarkers.clear();
    _pinSymbols.clear();
    _hazardOnMapCode = null; // a new style drops custom sources and layers
    unawaited(_syncFloodHazard());
    unawaited(_focusLocation());
    unawaited(_syncLocationMarker());
    unawaited(_syncPins());
    unawaited(_updatePinLabelPositions());
  }

  void _startStyleLoadTimer() {
    _styleLoadTimer?.cancel();
    _styleLoadTimer = Timer(const Duration(seconds: 12), () {
      if (mounted && !_styleLoaded) {
        if (_appliedStyleUrl == _darkStyleUrl && !_darkStyleFailed) {
          _darkStyleFailed = true;
          _appliedStyleUrl = _styleUrl;
          unawaited(_reloadMapStyle());
          return;
        }
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
    final dpr = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? MediaQuery.devicePixelRatioOf(context)
        : 1.0;
    final sync = _pinSyncQueue.then((_) async {
      if (syncId != _pinSyncId) return;
      try {
        for (final marker in _pinMarkers.keys.toList()) {
          await controller.removeCircle(marker);
        }
        _pinMarkers.clear();
        if (_pinSymbols.isNotEmpty) {
          await controller.removeSymbols(_pinSymbols.keys.toList());
          _pinSymbols.clear();
        }
        if (syncId != _pinSyncId) return;
        await _addPinIcons(controller);
        await controller.setSymbolIconAllowOverlap(true);
        await controller.setSymbolIconIgnorePlacement(true);
        for (final pin in widget.mapPins) {
          final radius = 12 + pin.intensity / 25;
          final marker = await controller.addCircle(
            ml.CircleOptions(
              geometry: ml.LatLng(pin.latitude, pin.longitude),
              circleRadius: radius,
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
          // White category symbol on the colored circle: what it is at a glance.
          final symbol = await controller.addSymbol(
            ml.SymbolOptions(
              geometry: ml.LatLng(pin.latitude, pin.longitude),
              iconImage: 'pin-${_pinKind(pin)}',
              // Icon image is in physical pixels; the circle radius is in dp.
              iconSize: radius * 1.3 * dpr / _pinIconPx,
            ),
          );
          _pinSymbols[symbol] = pin;
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

  static const _pinIconPx = 48.0;
  static const _pinIcons = {
    'flood': Icons.water,
    'evacuation': Icons.home_rounded,
    'road': Icons.add_road,
  };

  String _pinKind(MapPinUpdate pin) =>
      _pinIcons.containsKey(pin.category) ? pin.category : 'flood';

  /// Draws each category glyph (white, Material Icons font) into an image the
  /// map can use. Images are dropped with the style, so re-add on every sync.
  Future<void> _addPinIcons(ml.MapLibreMapController controller) async {
    for (final entry in _pinIcons.entries) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(entry.value.codePoint),
          style: TextStyle(
            fontSize: _pinIconPx * 0.8,
            fontFamily: entry.value.fontFamily,
            package: entry.value.fontPackage,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset((_pinIconPx - painter.width) / 2, (_pinIconPx - painter.height) / 2),
      );
      final image = await recorder
          .endRecording()
          .toImage(_pinIconPx.toInt(), _pinIconPx.toInt());
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png != null) {
        await controller.addImage('pin-${entry.key}', png.buffer.asUint8List());
      }
    }
  }

  /// Street level for the chosen town. Offline, MapLibre stretches the cached
  /// overview tiles if the town's detail pack isn't downloaded.
  double get _locationZoom => 14;

  Future<void> _focusLocation() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngZoom(
        ml.LatLng(widget.location.latitude, widget.location.longitude),
        _locationZoom,
      ),
      duration: const Duration(milliseconds: 900),
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
    _pinSymbols.clear();
    if (mounted) setState(() => _mapUnavailable = false);
    _startStyleLoadTimer();
    try {
      _appliedStyleUrl = _activeStyleUrl;
      await controller.setStyle(_appliedStyleUrl!);
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

  /// MapLibre on Android reports screen points in physical pixels, while
  /// Flutter lays out in logical pixels; iOS and web already use logical ones.
  Offset _toLogicalOffset(math.Point<num> point) {
    final scale =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? MediaQuery.devicePixelRatioOf(context)
            : 1.0;
    return Offset(point.x / scale, point.y / scale);
  }

  String _pinKey(MapPinUpdate pin) =>
      '${pin.category}|${pin.label}|${pin.latitude}|${pin.longitude}|${pin.status}|${pin.intensity}';

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
            styleString: _appliedStyleUrl ??= _activeStyleUrl,
            initialCameraPosition: ml.CameraPosition(
              target: ml.LatLng(
                widget.location.latitude,
                widget.location.longitude,
              ),
              zoom: _locationZoom,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraMove: _onCameraMove,
            onCameraIdle: _onCameraIdle,
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
            annotationOrder: const [ml.AnnotationType.circle, ml.AnnotationType.symbol],
            logoEnabled: true,
            scaleControlEnabled: true,
            translucentTextureSurface: false,
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
        // Map tools fold into one button, level with the category dropdown.
        Positioned(
          right: 12,
          top: 109,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.small(
                heroTag: 'map-tools-toggle',
                tooltip: _toolsOpen ? 'Hide map tools' : 'Map tools',
                backgroundColor:
                    _toolsOpen || _hazard != null || _showPinLabels
                        ? NimbusColors.primary
                        : context.nimbusPalette.surface,
                foregroundColor:
                    _toolsOpen || _hazard != null || _showPinLabels
                        ? Colors.white
                        : context.nimbusPalette.text,
                onPressed: () => setState(() => _toolsOpen = !_toolsOpen),
                child: Icon(_toolsOpen ? Icons.close : Icons.tune),
              ),
              if (_toolsOpen) ...[
                const SizedBox(height: 10),
                FloatingActionButton.small(
                  heroTag: 'offline-map-download',
                  tooltip: 'Manage offline maps',
                  onPressed: _openOfflineMaps,
                  child: const Icon(Icons.download_for_offline_outlined),
                ),
                const SizedBox(height: 10),
                FloatingActionButton.small(
                  heroTag: 'pin-label-toggle',
                  tooltip:
                      _showPinLabels ? 'Hide pin labels' : 'Show pin labels',
                  backgroundColor:
                      _showPinLabels
                          ? NimbusColors.primary
                          : context.nimbusPalette.surface,
                  foregroundColor:
                      _showPinLabels
                          ? Colors.white
                          : context.nimbusPalette.text,
                  onPressed: _togglePinLabels,
                  child: Icon(
                    _showPinLabels
                        ? Icons.label_off_outlined
                        : Icons.label_outline,
                  ),
                ),
                if (_townHazards != null) ...[
                  const SizedBox(height: 10),
                  PopupMenuButton<String>(
                    tooltip: 'Hazard maps',
                    onSelected: (kind) {
                      setState(() => _hazard = kind == 'off' ? null : kind);
                      unawaited(_syncFloodHazard());
                    },
                    itemBuilder:
                        (context) => [
                          for (final kind in _townHazards!.keys)
                            CheckedPopupMenuItem(
                              value: kind,
                              checked: _hazard == kind,
                              child: Text('${_hazardInfo[kind]!.$1} hazard'),
                            ),
                          const PopupMenuDivider(),
                          CheckedPopupMenuItem(
                            value: 'off',
                            checked: _hazard == null,
                            child: const Text('No hazard map'),
                          ),
                        ],
                    child: Material(
                      elevation: 3,
                      shape: const CircleBorder(),
                      color:
                          _hazard != null
                              ? NimbusColors.primary
                              : context.nimbusPalette.surface,
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(
                          _hazard != null
                              ? _hazardInfo[_hazard]!.$4
                              : Icons.layers_outlined,
                          color:
                              _hazard != null
                                  ? Colors.white
                                  : context.nimbusPalette.text,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                _ZoomControl(
                  zoom: _cameraZoom,
                  onZoom: (z) {
                    _cameraZoom = z;
                    unawaited(_controller?.moveCamera(ml.CameraUpdate.zoomTo(z)));
                    setState(() {});
                  },
                  onStep: (delta) => unawaited(_controller?.animateCamera(
                    delta > 0 ? ml.CameraUpdate.zoomIn() : ml.CameraUpdate.zoomOut(),
                    duration: const Duration(milliseconds: 250),
                  )),
                ),
              ],
            ],
          ),
        ),
        if (_downloading)
          Positioned(
            left: 12,
            right: 64,
            top: 190,
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
        if (_hazardAsset != null && !_mapUnavailable)
          Positioned(
            left: 12,
            bottom: widget.attributionBottomInset + 32,
            child: _FloodHazardLegend(kind: _hazard!),
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
        if (_selectedPin != null &&
            _selectedPinScreenPoint != null &&
            _cameraZoom >= 10.5)
          LayoutBuilder(
            builder: (context, constraints) {
              final pin = _selectedPin!;
              final point = _selectedPinScreenPoint!;
              const bubbleWidth = 230.0;
              final left =
                  math
                      .max(
                        8.0,
                        math.min(
                          point.dx - bubbleWidth / 2,
                          constraints.maxWidth - bubbleWidth - 8,
                        ),
                      )
                      .toDouble();
              final top = math.max(8.0, point.dy - 92).toDouble();
              final status = switch (pin.status) {
                'F' => pin.category == 'evacuation' ? 'Full' : 'Flooding now',
                'W' => 'Water rising / watch',
                'C' => 'No flooding now',
                'O' => 'Open',
                'L' => 'Limited access',
                'X' => 'Closed',
                _ => 'Status unavailable',
              };
              final category = switch (pin.category) {
                'flood' => 'Flood',
                'evacuation' => 'Evacuation center',
                _ => 'Road',
              };
              return Stack(
                children: [
                  Positioned(
                    left: point.dx - 6,
                    top: point.dy - 6,
                    child: IgnorePointer(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _pinColorFor(pin),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: top,
                    child: Material(
                      elevation: 6,
                      shadowColor: Colors.black26,
                      color: context.nimbusPalette.surface,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        width: bubbleWidth,
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                        decoration: BoxDecoration(
                          border: Border.all(color: context.nimbusPalette.line),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    pin.label,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    category,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.nimbusPalette.muted,
                                    ),
                                  ),
                                  Text(
                                    status,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  Text(
                                    pinAmountText(pin),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            InkWell(
                              onTap:
                                  () => setState(() {
                                    _selectedPin = null;
                                    _selectedPinScreenPoint = null;
                                  }),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.close, size: 16),
                              ),
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
        if (_showPinLabels)
          ...widget.mapPins.map((pin) {
            final position = _pinLabelPositions[_pinKey(pin)];
            if (position == null) return const SizedBox.shrink();
            return Positioned(
              // Bubble tail tip sits 169px from the left, 73px from the top.
              left: position.dx - 169,
              top: position.dy - 80,
              child: _PinSpeechBubble(pin: pin),
            );
          }).toList(),
      ],
    ),
  );

  /// Adds, swaps or removes the NOAH flood hazard layer to match the toggle
  /// and the selected town. Calls are queued so they never overlap.
  Future<void> _syncFloodHazard() {
    return _hazardQueue = _hazardQueue
        .then((_) async {
          final controller = _controller;
          if (!mounted || controller == null || !_styleLoaded) return;
          final asset = _hazardAsset;
          final wanted = asset;
          if (wanted == _hazardOnMapCode) return;
          try {
            if (_hazardOnMapCode != null) {
              await controller.removeLayer(_hazardLayerId);
              await controller.removeSource(_hazardSourceId);
              _hazardOnMapCode = null;
            }
            if (wanted == null) return;
            final geojson =
                jsonDecode(await rootBundle.loadString(wanted))
                    as Map<String, dynamic>;
            await controller.addGeoJsonSource(_hazardSourceId, geojson);
            await controller.addFillLayer(
              _hazardSourceId,
              _hazardLayerId,
              ml.FillLayerProperties(
                fillColor: [
                  'match',
                  ['get', 'Var'],
                  3,
                  _hexColor(_hazardHigh),
                  2,
                  _hexColor(_hazardMedium),
                  _hexColor(_hazardLow),
                ],
                fillOpacity: 0.45,
              ),
              // Keep street names and the LGU pins readable on top.
              belowLayerId: await _firstLabelLayerId(controller),
            );
            _hazardOnMapCode = wanted;
          } on PlatformException catch (error) {
            _showMessage(
              'Could not show the hazard map: ${error.message ?? error.code}',
            );
          }
        })
        .catchError((_) {});
  }

  /// The first symbol (label) layer in the style, so fills go underneath it.
  Future<String?> _firstLabelLayerId(
    ml.MapLibreMapController controller,
  ) async {
    try {
      final style = await controller.getStyle();
      if (style == null) return null;
      final layers = (jsonDecode(style) as Map<String, dynamic>)['layers'];
      if (layers is! List) return null;
      for (final layer in layers) {
        if (layer is Map && layer['type'] == 'symbol')
          return layer['id'] as String?;
      }
    } catch (_) {}
    return null;
  }

  void _togglePinLabels() {
    setState(() {
      _showPinLabels = !_showPinLabels;
      _pinLabelPositions.clear();
    });
    if (_showPinLabels) unawaited(_updatePinLabelPositions());
  }

  Future<void> _updatePinLabelPositions() async {
    final controller = _controller;
    if (!_showPinLabels || controller == null || !_styleLoaded) return;
    if (_pinLabelUpdateInFlight) {
      _pinLabelUpdatePending = true;
      return;
    }
    if (widget.mapPins.isEmpty) {
      if (_pinLabelPositions.isNotEmpty) {
        setState(_pinLabelPositions.clear);
      }
      return;
    }
    _pinLabelUpdateInFlight = true;
    try {
      final pins = widget.mapPins.toList();
      final points = await controller.toScreenLocationBatch([
        for (final pin in pins) ml.LatLng(pin.latitude, pin.longitude),
      ]);
      final next = <String, Offset>{
        for (var i = 0; i < pins.length && i < points.length; i++)
          _pinKey(pins[i]): _toLogicalOffset(points[i]),
      };
      if (!mounted || !_showPinLabels) return;
      setState(() {
        _pinLabelPositions
          ..clear()
          ..addAll(next);
      });
    } catch (_) {
    } finally {
      _pinLabelUpdateInFlight = false;
      if (_pinLabelUpdatePending) {
        _pinLabelUpdatePending = false;
        unawaited(_updatePinLabelPositions());
      }
    }
  }
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

class _PinSpeechBubble extends StatelessWidget {
  const _PinSpeechBubble({required this.pin});

  final MapPinUpdate pin;

  @override
  Widget build(BuildContext context) {
    final status = switch (pin.status) {
      'F' => pin.category == 'evacuation' ? 'Full' : 'Flooding',
      'W' => 'Watch',
      'C' => 'Clear',
      'O' => 'Open',
      'L' => 'Limited',
      'X' => 'Closed',
      _ => 'Unknown',
    };
    final category = switch (pin.category) {
      'flood' => 'Flood',
      'evacuation' => 'Evacuation',
      _ => 'Road',
    };

    return SizedBox(
      width: 210,
      height: 70,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: 34,
            bottom: 0,
            child: Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: context.nimbusPalette.surface,
                  border: Border(
                    right: BorderSide(color: context.nimbusPalette.line),
                    bottom: BorderSide(color: context.nimbusPalette.line),
                  ),
                ),
              ),
            ),
          ),
          Material(
            elevation: 5,
            color: context.nimbusPalette.surface,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(5),
            ),
            child: Container(
              width: 210,
              height: 58,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                border: Border.all(color: _pinColorFor(pin), width: 2),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(5),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pin.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$category · $status',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.nimbusPalette.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FloodHazardLegend extends StatelessWidget {
  const _FloodHazardLegend({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    Widget swatch(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 12.5, color: palette.text)),
      ],
    );
    return Semantics(
      container: true,
      label:
          '${_hazardInfo[kind]!.$2}. Yellow low, orange medium, red high. '
          '${_hazardInfo[kind]!.$3}.',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: palette.surface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: NimbusColors.primary.withValues(alpha: 0.12),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _hazardInfo[kind]!.$2,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              children: [
                swatch(_hazardLow, 'Low'),
                swatch(_hazardMedium, 'Medium'),
                swatch(_hazardHigh, 'High'),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _hazardInfo[kind]!.$3,
              style: TextStyle(fontSize: 11, color: palette.muted),
            ),
          ],
        ),
      ),
    );
  }
}


/// Vertical zoom control: + at the top, a slider (street level up top, whole
/// country at the bottom) and − below. Lives in the foldable map tools.
class _ZoomControl extends StatelessWidget {
  const _ZoomControl({required this.zoom, required this.onZoom, required this.onStep});
  static const _min = 4.0, _max = 18.0;
  final double zoom;
  final ValueChanged<double> onZoom;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    Widget step(IconData icon, int delta, String tip) => IconButton(
      tooltip: tip,
      onPressed: () => onStep(delta),
      icon: Icon(icon, color: palette.text),
      visualDensity: VisualDensity.compact,
    );
    return Material(
      elevation: 3,
      color: palette.surface,
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: 40,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            step(Icons.add, 1, 'Zoom in'),
            SizedBox(
              height: 150,
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: zoom.clamp(_min, _max),
                    min: _min,
                    max: _max,
                    semanticFormatterCallback: (v) => 'Zoom ${v.toStringAsFixed(0)}',
                    onChanged: onZoom,
                  ),
                ),
              ),
            ),
            step(Icons.remove, -1, 'Zoom out'),
          ],
        ),
      ),
    );
  }
}
