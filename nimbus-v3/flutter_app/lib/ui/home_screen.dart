import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../codec/nimbus_codec.dart' as codec;
import '../data/philippine_location.dart';
import '../data/town_pack.dart';
import '../lgu/lgu_api.dart';
import '../sms/sms_service.dart';
import '../weather/open_meteo_service.dart';
import 'location_picker.dart';
import 'storm_map.dart';
import 'theme.dart';

const _tabs = [
  (
    'O',
    'Overview',
    Icons.dashboard_outlined,
    'Overview',
    'Get all updates by SMS',
  ),
  (
    'Q',
    'Storm',
    Icons.cloud_outlined,
    'Storm update',
    'Get storm update by SMS',
  ),
  (
    'P',
    'Map pins',
    Icons.location_on_outlined,
    'LGU map pins',
    'Get map pins by SMS',
  ),
  ('F', 'Floods', Icons.waves, 'Flood status', 'Get flood areas by SMS'),
  (
    'E',
    'Evac',
    Icons.home_outlined,
    'Evacuation centers',
    'Get evacuation centers by SMS',
  ),
  (
    'C',
    'Class status',
    Icons.school_outlined,
    'Class status',
    'Get class status by SMS',
  ),
  ('R', 'Road status', Icons.add_road, 'Road status', 'Get road status by SMS'),
];
const _rain = [
  'No rain',
  'Light rain',
  'Moderate rain',
  'Heavy rain',
  'Intense rain',
];
const _classes = [
  'No suspension',
  'All levels',
  'Preschool to SHS',
  'Preschool to grade 10',
  'Preschool to grade 6',
  'Preschool only',
];
const _level = {
  'H': 'High flood risk',
  'M': 'Medium flood risk',
  'L': 'Low flood risk',
};
const _road = {
  'O': ('Open', 'Open to all vehicles'),
  'L': ('Light vehicles only', 'Trucks and buses turned back'),
  'X': ('Closed', 'Not passable, use another route'),
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.sms,
    required this.locations,
    required this.outline,
    required this.onBack,
    required this.onSettings,
  });

  final SmsService sms;
  final List<PhilippineLocation> locations;
  final PhilippineOutline outline;
  final VoidCallback onBack;
  final VoidCallback onSettings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _tab = 'O';
  late PhilippineLocation _location;
  final _panelController = DraggableScrollableController();
  LguApiService _lguApi = LguApiService();
  final _weatherService = OpenMeteoService();
  bool _waiting = false;
  bool _apiLoading = true;
  bool _panelExpanded = false;
  bool _showSaved = false;
  String? _apiError;
  LguUpdate? _publishedUpdate;
  List<MapPinUpdate> _smsPins = [];
  bool _smsPinSnapshotReceived = false;
  List<SavedUpdate> _saved = [];
  SavedUpdate? _viewing;
  WeatherSnapshot? _weatherFallback;
  bool _weatherFallbackLoading = false;
  String? _weatherFallbackError;
  DateTime? _requestStartedAt;
  String? _requestTownCode;
  String? _requestType;
  int _weatherRequestId = 0;
  Timer? _weatherFallbackTimer;
  OverlayEntry? _pinBubble;
  Timer? _pinBubbleTimer;
  StreamSubscription<SavedUpdate>? _sub;
  StreamSubscription<String>? _noticeSub;
  int _focusRequest = 0;
  StreamSubscription<void>? _clearSub;
  Timer? _refreshTimer;
  bool _publishedUpdateLoaded = false;
  bool _demoMode = false;

  @override
  void initState() {
    super.initState();
    _panelController.addListener(_syncPanelExpanded);
    _location = widget.locations.first;
    unawaited(_initializeDemoAndRefresh());
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshPublishedUpdate(_location.code);
    });
    _sub = widget.sms.replies.listen((u) async {
      final saved = await widget.sms.saved();
      if (!mounted) return;
      final isCurrentReply =
          u.type == _requestType &&
          u.townCode == _requestTownCode &&
          _requestStartedAt != null &&
          !u.received.isBefore(_requestStartedAt!);
      setState(() {
        _saved = saved;
        if (u.type == 'P' && u.townCode == _location.smsCode) {
          final pinReply = codec.decode(u.sms);
          if (pinReply != null && pinReply.valid) {
            _smsPins = [
              for (final pin in pinReply.pins)
                MapPinUpdate(
                  category: pin.category,
                  label: pin.label,
                  latitude: pin.latitude,
                  longitude: pin.longitude,
                  status: pin.status,
                  intensity: pin.intensity,
                ),
            ];
            _smsPinSnapshotReceived = true;
          }
        }
        if (isCurrentReply) {
          _waiting = false;
          if (u.type == 'Q') {
            _weatherFallbackTimer?.cancel();
            _weatherFallback = null;
            _weatherFallbackLoading = false;
            _weatherFallbackError = null;
          }
        }
      });
    });
    unawaited(widget.sms.setCurrentTown(_location.smsCode, _location.name));
    _clearSub = widget.sms.cleared.listen((_) async {
      final saved = await widget.sms.saved();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _viewing = null;
        _smsPins = [];
        _smsPinSnapshotReceived = false;
        _waiting = false;
      });
    });
    // e.g. "Too many requests from this number. Try again in 6 min."
    _noticeSub = widget.sms.notices.listen((text) {
      if (!mounted) return;
      _weatherFallbackTimer?.cancel();
      setState(() => _waiting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 8)),
      );
    });
    widget.sms.saved().then((s) {
      if (mounted) setState(() => _saved = s);
    });
    unawaited(_restoreApiUrl());
  }

  @override
  void dispose() {
    _panelController
      ..removeListener(_syncPanelExpanded)
      ..dispose();
    _refreshTimer?.cancel();
    _weatherFallbackTimer?.cancel();
    _pinBubbleTimer?.cancel();
    _pinBubble?.remove();
    _weatherRequestId++;
    _sub?.cancel();
    _noticeSub?.cancel();
    _clearSub?.cancel();
    super.dispose();
  }

  Future<void> _initializeDemoAndRefresh() async {
    await _applyDemoMode();
    if (!mounted || _demoMode) return;
    await _refreshPublishedUpdate(_location.code);
    await _refreshSmsPins(_location.smsCode);
  }

  Future<void> _refreshPublishedUpdate(String townCode) async {
    if (_demoMode) return;
    if (!mounted) return;
    setState(() {
      _apiLoading = _publishedUpdate == null;
      _apiError = null;
    });
    try {
      final update = await _lguApi.fetchTown(townCode);
      if (!mounted || townCode != _location.code) return;
      setState(() {
        _publishedUpdate = update;
        _apiLoading = false;
        _publishedUpdateLoaded = true;
        _smsPinSnapshotReceived = false;
        _smsPins = [];
      });
    } on LguApiException catch (error) {
      if (!mounted || townCode != _location.code) return;
      setState(() {
        _apiError = error.message;
        _apiLoading = false;
      });
    } on FormatException catch (error) {
      if (!mounted || townCode != _location.code) return;
      setState(() {
        _apiError = 'The API returned invalid data: ${error.message}';
        _apiLoading = false;
      });
    }
  }

  Future<void> _refreshSmsPins(String townCode) async {
    try {
      final snapshot = await widget.sms.latestPinSnapshot(townCode);
      if (!mounted || townCode != _location.smsCode) return;
      setState(() {
        _smsPinSnapshotReceived = snapshot != null;
        _smsPins = [
          for (final pin in snapshot?.pins ?? const <codec.MapPin>[])
            MapPinUpdate(
              category: pin.category,
              label: pin.label,
              latitude: pin.latitude,
              longitude: pin.longitude,
              status: pin.status,
              intensity: pin.intensity,
            ),
        ];
      });
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved SMS pin data is invalid: $error')),
      );
    }
  }

  List<MapPinUpdate> get _mapPins =>
      _publishedUpdateLoaded
          ? _publishedUpdate?.mapPins ?? const []
          : _smsPinSnapshotReceived
          ? _smsPins
          : _smsLguUpdate?.mapPins ?? const [];

  /// What residents see offline: the LGU picture rebuilt from the newest saved
  /// SMS reply of each type for this town. Null when no replies exist.
  LguUpdate? get _smsLguUpdate {
    final key = (identityHashCode(_saved), _location.smsCode);
    if (key == _smsLguKey) return _smsLguCache;
    _smsLguKey = key;
    return _smsLguCache = _buildSmsLguUpdate();
  }

  (int, String)? _smsLguKey;
  LguUpdate? _smsLguCache;

  LguUpdate? _buildSmsLguUpdate() {
    final code = _location.smsCode;
    final latest = <String, (codec.Reply, DateTime)>{};
    for (final u in _saved) {
      if (u.townCode != code || latest.containsKey(u.type)) continue;
      final r = codec.decode(u.sms);
      if (r != null && r.valid) latest[u.type] = (r, u.received);
    }
    if (latest.isEmpty) return null;
    String name(codec.Item i, String fallback) => i.customName ?? '$fallback ${i.index}';
    final q = latest['Q']?.$1;
    var notice = q?.notice ?? '';
    final noStorm = notice.toLowerCase().indexOf('no current storm');
    if (noStorm >= 0) notice = notice.substring(0, noStorm).trim();
    return LguUpdate(
      townCode: code,
      classes: q?.storm?.classes ?? 0,
      notice: notice,
      floodAreas: [
        for (final i in latest['F']?.$1.items ?? const <codec.Item>[])
          FloodAreaUpdate(name: name(i, 'Area'), level: i.level ?? 'L', status: i.now ?? 'C'),
      ],
      evacuationCenters: [
        for (final i in latest['E']?.$1.items ?? const <codec.Item>[])
          EvacuationCenterUpdate(name: name(i, 'Site'), status: i.status ?? 'O', percentFull: i.percentFull ?? 0),
      ],
      roadStatuses: [
        for (final i in latest['R']?.$1.items ?? const <codec.Item>[])
          RoadStatusUpdate(name: name(i, 'Road'), status: i.status ?? 'O'),
      ],
      mapPins: [
        for (final pin in latest['P']?.$1.pins ?? const <codec.MapPin>[])
          MapPinUpdate(
            category: pin.category,
            label: pin.label,
            latitude: pin.latitude,
            longitude: pin.longitude,
            status: pin.status,
            intensity: pin.intensity,
          ),
      ],
      updatedAt: latest.values.map((e) => e.$2).reduce((a, b) => a.isAfter(b) ? a : b),
    );
  }

  void _onLocationChanged(
    PhilippineLocation location, {
    bool clearViewing = true,
  }) {
    _weatherFallbackTimer?.cancel();
    _weatherRequestId++;
    unawaited(widget.sms.setCurrentTown(location.smsCode, location.name));
    _focusRequest++; // zoom in even when the same town is picked again
    setState(() {
      _location = location;
      if (clearViewing) _viewing = null;
      _publishedUpdate = null;
      _publishedUpdateLoaded = false;
      _apiError = null;
      _apiLoading = true;
      _waiting = false;
      _weatherFallback = null;
      _weatherFallbackLoading = false;
      _weatherFallbackError = null;
      _smsPinSnapshotReceived = false;
      _smsPins = [];
    });
    _refreshPublishedUpdate(location.code);
    _refreshSmsPins(location.smsCode);
  }

  void _syncPanelExpanded() {
    if (!_panelController.isAttached) return;
    final expanded = _panelController.size > 0.22;
    if (expanded != _panelExpanded && mounted) {
      setState(() => _panelExpanded = expanded);
    }
  }

  void _animatePanel(bool expanded) {
    if (!_panelController.isAttached) return;
    unawaited(
      _panelController.animateTo(
        expanded ? _panelOpen : _panelClosed,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _selectTab(String tab) {
    setState(() {
      _tab = tab;
      _viewing = null;
      _showSaved = false;
      _panelExpanded = true;
    });
    _animatePanel(true);
  }

  static const _panelClosed = 0.17, _panelOpen = 0.55, _panelFull = 0.9;

  /// Dragging the handle/title moves the panel directly (not just the list).
  void _dragPanel(double dy) {
    if (!_panelController.isAttached) return;
    final height = MediaQuery.sizeOf(context).height;
    _panelController.jumpTo(
      (_panelController.size - dy / height).clamp(_panelClosed, _panelFull),
    );
  }

  /// On release: a flick goes one stop in its direction, otherwise snap to the nearest stop.
  void _endDragPanel(double velocity) {
    if (!_panelController.isAttached) return;
    const stops = [_panelClosed, _panelOpen, _panelFull];
    final size = _panelController.size;
    double target;
    if (velocity < -300) {
      target = stops.firstWhere((s) => s > size + 0.02, orElse: () => _panelFull);
    } else if (velocity > 300) {
      target = stops.lastWhere((s) => s < size - 0.02, orElse: () => _panelClosed);
    } else {
      target = stops.reduce((a, b) => (a - size).abs() < (b - size).abs() ? a : b);
    }
    setState(() => _panelExpanded = target > _panelClosed + 0.05);
    unawaited(
      _panelController.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _togglePanel() {
    final expand = !_panelExpanded;
    setState(() => _panelExpanded = expand);
    _animatePanel(expand);
  }

  PhilippineLocation? _locationForCode(String code) {
    for (final location in widget.locations) {
      if (location.code == code || location.smsCode == code) return location;
    }
    return null;
  }

  SavedUpdate? get _latest {
    if (_viewing != null) return _viewing;
    final smsType = _smsType;
    for (final u in _saved) {
      if (u.type == smsType && u.townCode == _location.smsCode) return u;
    }
    return null;
  }

  String get _smsType => _tab == 'O' || _tab == 'C' ? 'Q' : _tab;

  Future<void> _ask() async {
    _weatherFallbackTimer?.cancel();
    if (_demoMode) {
      await _loadDemoReply(_smsType, '0412');
      final saved = await widget.sms.saved();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _waiting = false;
        _viewing = null;
        _showSaved = false;
        _panelExpanded = true;
      });
      _animatePanel(true);
      return;
    }
    final requestId = ++_weatherRequestId;
    final requestStartedAt = DateTime.now();
    final requestLocation = _location;
    _requestStartedAt = requestStartedAt;
    _requestTownCode = requestLocation.smsCode;
    _requestType = _smsType;
    setState(() {
      _waiting = true;
      _viewing = null;
      _showSaved = false;
      _weatherFallback = null;
      _weatherFallbackLoading = false;
      _weatherFallbackError = null;
    });
    try {
      // Overview asks for everything (A); the relay replies once per update type.
      await widget.sms.ask(_tab == 'O' ? 'A' : _smsType, _location.smsCode);
      if (!mounted || requestId != _weatherRequestId) return;
      if (_smsType == 'Q') {
        _weatherFallbackTimer = Timer(const Duration(seconds: 20), () {
          if (!mounted ||
              !_waiting ||
              requestId != _weatherRequestId ||
              _location.code != requestLocation.smsCode) {
            return;
          }
          final latest = _latest;
          if (latest != null &&
              latest.type == 'Q' &&
              latest.townCode == requestLocation.smsCode &&
              !latest.received.isBefore(requestStartedAt)) {
            return;
          }
          setState(() => _waiting = false);
          unawaited(_loadFallbackWeather(requestId, requestLocation));
        });
      }
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() => _waiting = false);
      unawaited(_loadDemoReply(_smsType, requestLocation.smsCode));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${error.message}. Loaded mock demo data instead.',
          ),
        ),
      );
    }
  }

  Future<void> _loadFallbackWeather(
    int requestId,
    PhilippineLocation location,
  ) async {
    setState(() {
      _weatherFallbackLoading = true;
      _weatherFallbackError = null;
    });
    try {
      final weather = await _weatherService.current(
        latitude: location.latitude,
        longitude: location.longitude,
      );
      if (!mounted || requestId != _weatherRequestId) return;
      setState(() {
        _weatherFallback = weather;
        _weatherFallbackLoading = false;
      });
    } on OpenMeteoException catch (error) {
      if (!mounted || requestId != _weatherRequestId) return;
      setState(() {
        _weatherFallbackLoading = false;
        _weatherFallbackError = error.message;
      });
    }
  }

  Future<void> _showMapPin(MapPinUpdate pin) async {
    _pinBubbleTimer?.cancel();
    _pinBubble?.remove();

    final category = switch (pin.category) {
      'flood' => 'Flood',
      'evacuation' => 'Evacuation center',
      _ => 'Road',
    };
    final status = switch (pin.status) {
      'F' => 'Flooding now / full',
      'W' => 'Water rising / watch',
      'C' => 'No flooding now',
      'O' => 'Open',
      'L' => 'Light vehicles only',
      'X' => 'Closed',
      _ => 'Unknown',
    };

    _pinBubble = OverlayEntry(
      builder:
          (overlayContext) => Positioned(
            left: 16,
            right: 16,
            bottom: 116,
            child: Material(
              color: Colors.transparent,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 430),
                  padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                  decoration: BoxDecoration(
                    color: Theme.of(overlayContext).colorScheme.surface,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18),
                      bottomRight: Radius.circular(4),
                    ),
                    border: Border.all(color: context.nimbusPalette.line),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text('$category · $status'),
                            Text(
                              pinAmountText(pin),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () {
                          _pinBubbleTimer?.cancel();
                          _pinBubble?.remove();
                          _pinBubble = null;
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
    );

    Overlay.of(context).insert(_pinBubble!);
    _pinBubbleTimer = Timer(const Duration(seconds: 8), () {
      _pinBubble?.remove();
      _pinBubble = null;
    });
  }

  Future<void> _restoreApiUrl() async {
    const storage = FlutterSecureStorage();
    final saved = await storage.read(key: LguApiService.apiUrlStorageKey);
    if (saved == null || saved.trim().isEmpty) return;
    final uri = Uri.tryParse(saved.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty)
      return;
    if (!mounted) return;
    _lguApi = LguApiService(baseUri: uri);
    _refreshPublishedUpdate(_location.code);
  }

  Future<void> _applyDemoMode() async {
    final enabled = await widget.sms.getDemoMode();
    if (!enabled || !mounted) return;

    PhilippineLocation? batangas;
    for (final location in widget.locations) {
      if (location.code == '0401005000' || location.smsCode == '0412') {
        batangas = location;
        break;
      }
    }
    if (batangas == null) return;

    final update = LguUpdate(
      townCode: '0401005000',
      classes: 1,
      notice: 'Heavy rain and gusty winds are possible. Stay alert for water rising and follow LGU evacuation instructions.',
      floodAreas: const [
        FloodAreaUpdate(name: 'Poblacion riverside', level: 'H', status: 'F'),
        FloodAreaUpdate(name: 'Alangilan low road', level: 'M', status: 'W'),
        FloodAreaUpdate(name: 'Calicanto creek', level: 'M', status: 'W'),
        FloodAreaUpdate(name: 'City proper', level: 'L', status: 'C'),
      ],
      evacuationCenters: const [
        EvacuationCenterUpdate(name: 'Central School', status: 'O', percentFull: 68),
        EvacuationCenterUpdate(name: 'University gymnasium', status: 'O', percentFull: 42),
        EvacuationCenterUpdate(name: 'Poblacion covered court', status: 'F', percentFull: 100),
      ],
      roadStatuses: const [
        RoadStatusUpdate(name: 'Riverside road', status: 'X'),
        RoadStatusUpdate(name: 'Market crossing', status: 'X'),
        RoadStatusUpdate(name: 'Alangilan road', status: 'L'),
        RoadStatusUpdate(name: 'Main highway', status: 'O'),
      ],
      mapPins: const [
        MapPinUpdate(category: 'flood', label: 'Market crossing', latitude: 13.75634, longitude: 121.05831, status: 'F', intensity: 95),
        MapPinUpdate(category: 'evacuation', label: 'Central School', latitude: 13.7581, longitude: 121.0602, status: 'O', intensity: 68),
        MapPinUpdate(category: 'road', label: 'Riverside road', latitude: 13.7542, longitude: 121.0568, status: 'X', intensity: 100),
      ],
      updatedAt: DateTime.utc(2026, 11, 9, 9),
    );

    setState(() {
      _demoMode = true;
      _location = batangas!;
      _publishedUpdate = update;
      _publishedUpdateLoaded = true;
      _apiLoading = false;
      _apiError = null;
      _weatherFallback = WeatherSnapshot(
        temperatureC: 29.4,
        apparentTemperatureC: 34.1,
        humidityPercent: 78,
        precipitationMm: 1.2,
        windKph: 18.5,
        gustKph: 27.1,
        description: 'Thunderstorms nearby',
        observedAt: DateTime.utc(2026, 11, 9, 9),
      );
      _weatherFallbackLoading = false;
      _weatherFallbackError = null;
    });

    await _loadDemoReply('Q', '0412');
    await _loadDemoReply('F', '0412');
    await _loadDemoReply('E', '0412');
    await _loadDemoReply('R', '0412');
    await _loadDemoReply('C', '0412');
    await _loadDemoReply('P', '0412');

    final saved = await widget.sms.saved();
    if (mounted) setState(() {
      _saved = saved;
      _waiting = false;
    });
  }

  Future<void> _loadDemoReply(String type, String townCode) async {
    final raw = await rootBundle.loadString('assets/data/demo_sms_updates.json');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final defaults = data['defaults'] as Map<String, dynamic>;
    final towns = data['towns'] as Map<String, dynamic>;
    final town = towns[townCode] as Map<String, dynamic>?;
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';

    String sms;
    if (type == 'P') {
      final pins = <codec.MapPin>[];
      for (final item in (town?['pins'] as List<dynamic>? ?? const [])) {
        final pin = item as Map<String, dynamic>;
        pins.add(codec.MapPin(
          category: pin['category'] as String,
          label: pin['label'] as String,
          latitude: (pin['latitude'] as num).toDouble(),
          longitude: (pin['longitude'] as num).toDouble(),
          status: pin['status'] as String,
          intensity: pin['intensity'] as int,
        ));
      }
      sms = codec.encodePins(townCode, pins, time);
    } else {
      final fields = <String>[];
      if (town?[type] is List) {
        fields.addAll((town![type] as List).cast<String>());
      } else {
        fields.addAll(
          (defaults[type] as List<dynamic>? ?? const []).cast<String>(),
        );
      }
      final notice = type == 'Q'
          ? (town?['notice'] as String? ??
              defaults['notice'] as String)
          : '';
      sms = codec.encode(type, townCode, fields, time, notice);
    }
    await widget.sms.injectDemoReply(sms);
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    final reply = latest == null ? null : codec.decode(latest.sms);
    final town = townForLocation(_location);
    final warning =
        // Only a received storm reply with an actual signal may change the title.
        (reply?.type == 'Q' && (int.tryParse(reply!.storm!.warning) ?? 0) > 0
            ? town.warnings[reply.storm!.warning]
            : null) ??
        ('Storm update', '');
    final activeTab = _tabs.firstWhere((tab) => tab.$1 == _tab);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: StormMap(
              location: _location,
              focusRequest: _focusRequest,
              outline: widget.outline,
              floodReported:
                  _publishedUpdate?.floodAreas.any((a) => a.status == 'F') ??
                  false,
              mapPins: _mapPins,
              onPinTapped: null,
              attributionBottomInset:
                  MediaQuery.sizeOf(context).height *
                      (_panelExpanded ? _panelOpen : _panelClosed) +
                  8,
              errorOverlayLeftInset: 84,
            ),
          ),
          SafeArea(
            child: Stack(
              children: [
                Positioned(
                  left: 12,
                  top: 8,
                  child: _RoundButton(
                    icon: Icons.arrow_back,
                    label: 'Back to NIMBUS',
                    selected: false,
                    onTap: widget.onBack,
                  ),
                ),
                Positioned(
                  right: 12,
                  top: 8,
                  child: _RoundButton(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    selected: false,
                    onTap: widget.onSettings,
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: _TopPill(
                    title: _tab == 'Q' ? warning.$1 : activeTab.$4,
                    subtitle: '${_location.name} · ${_location.region}',
                    onTap: () async {
                      final picked = await showLocationPicker(
                        context,
                        widget.locations,
                        _location,
                      );
                      if (picked != null) _onLocationChanged(picked);
                    },
                  ),
                ),
                Positioned(
                  left: 12,
                  top: 84,
                  child: _CategoryDropdown(
                    selected: _tab,
                    onSelect: _selectTab,
                  ),
                ),
              ],
            ),
          ),
          DraggableScrollableSheet(
            controller: _panelController,
            initialChildSize: 0.17,
            minChildSize: 0.17,
            maxChildSize: _panelFull,
            snap: true,
            snapSizes: const [_panelOpen],
            builder:
                (context, scroll) => _Sheet(
                  scroll: scroll,
                  expanded: _panelExpanded,
                  onToggleExpanded: _togglePanel,
                  onDragPanel: _dragPanel,
                  onDragPanelEnd: _endDragPanel,
                  selected: _tab,
                  title: activeTab.$4,
                  cta: activeTab.$5,
                  location: _location,
                  locations: widget.locations,
                  onLocation: _onLocationChanged,
                  showSaved: _showSaved,
                  onPane:
                      (saved) => setState(() {
                        _showSaved = saved;
                        if (!saved) _viewing = null;
                      }),
                  saved: _saved,
                  onOpenSaved: (u) {
                    final savedLocation = _locationForCode(u.townCode);
                    setState(() {
                      _viewing = u;
                      _tab = u.type;
                      _showSaved = false;
                      if (savedLocation != null) _location = savedLocation;
                    });
                    if (savedLocation != null) {
                      _onLocationChanged(savedLocation, clearViewing: false);
                    }
                  },
                  waiting: _waiting,
                  latest: latest,
                  reply: reply,
                  publishedUpdate: _publishedUpdate ?? _smsLguUpdate,
                  smsPins: _smsPins,
                  smsPinSnapshotReceived: _smsPinSnapshotReceived,
                  weatherFallback: _weatherFallback,
                  weatherFallbackLoading: _weatherFallbackLoading,
                  weatherFallbackError: _weatherFallbackError,
                  apiLoading: _apiLoading,
                  apiError: _apiError,
                  onRefreshApi: () => _refreshPublishedUpdate(_location.code),
                  onAsk: _waiting ? null : _ask,
                ),
          ),
        ],
      ),
    );
  }
}

class _TopPill extends StatelessWidget {
  const _TopPill({required this.title, required this.subtitle, required this.onTap});
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Change town. $subtitle',
    child: Container(
      margin: const EdgeInsets.only(top: 8),
      width: 240,
      decoration: _floating(context, 16),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 12, color: context.nimbusPalette.muted),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.expand_more, size: 20, color: context.nimbusPalette.muted),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

BoxDecoration _floating(BuildContext context, double radius) => BoxDecoration(
  color: context.nimbusPalette.surface,
  borderRadius: BorderRadius.circular(radius),
  boxShadow: [
    BoxShadow(
      color: NimbusColors.primary.withValues(alpha: 0.14),
      blurRadius: 14,
      offset: const Offset(0, 4),
    ),
  ],
);

class _CategoryDropdown extends StatelessWidget {
  const _CategoryDropdown({required this.selected, required this.onSelect});
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final active = _tabs.firstWhere((tab) => tab.$1 == selected);
    return PopupMenuButton<String>(
      tooltip: 'Choose map information',
      onSelected: onSelect,
      itemBuilder:
          (context) => [
            for (final tab in _tabs)
              PopupMenuItem(
                value: tab.$1,
                child: Row(
                  children: [
                    Icon(tab.$3, size: 20),
                    const SizedBox(width: 12),
                    Text(tab.$2),
                  ],
                ),
              ),
          ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: _floating(context, 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(active.$3, color: NimbusColors.primary),
            const SizedBox(width: 8),
            Text(
              active.$2,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Material(
      color: selected ? NimbusColors.primary : context.nimbusPalette.surface,
      shape: const CircleBorder(),
      elevation: 3,
      shadowColor: NimbusColors.primary.withValues(alpha: 0.3),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: NimbusSizes.minTap,
          child: Icon(
            icon,
            color:
                selected ? NimbusColors.onPrimary : context.nimbusPalette.text,
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Bottom sheet: shared look
// ---------------------------------------------------------------------------

/// Radius for cards and groups inside the sheet (the sheet itself is 18).
const _r = 12.0;

enum _Sev { danger, warning, ok, neutral }

Color _sevColor(BuildContext context, _Sev sev) => switch (sev) {
  _Sev.danger => NimbusColors.danger,
  _Sev.warning => NimbusColors.warning,
  _Sev.ok => NimbusColors.ok,
  _Sev.neutral => context.nimbusPalette.muted,
};

/// Status shape, so status never relies on color alone.
IconData _sevIcon(_Sev sev, {String? word}) => switch (sev) {
  _Sev.danger => word == 'Closed' ? Icons.block_rounded : Icons.error_rounded,
  _Sev.warning => Icons.warning_rounded,
  _Sev.ok => Icons.check_circle_rounded,
  _Sev.neutral => Icons.remove_circle_outline,
};

_Sev _sevOfColor(Color color) {
  if (color == NimbusColors.danger) return _Sev.danger;
  if (color == NimbusColors.warning) return _Sev.warning;
  if (color == NimbusColors.ok) return _Sev.ok;
  return _Sev.neutral;
}

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

int _floodRank(FloodAreaUpdate a) => switch (a.status) {
  'F' => 0,
  'W' => 1,
  _ => 2,
};

int _roadRank(RoadStatusUpdate r) => switch (r.status) {
  'X' => 0,
  'L' => 1,
  _ => 2,
};

int _evacRank(EvacuationCenterUpdate c) => c.status == 'F' || c.status == 'X'
    ? 0
    : c.percentFull >= 85
    ? 1
    : 2;

/// Dart's List.sort is not stable; keep the LGU's order within a rank.
List<T> _stableSort<T>(List<T> items, int Function(T) rank) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final byRank = rank(a.$2).compareTo(rank(b.$2));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

String _norm(String s) =>
    s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _whenText(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final clock = TimeOfDay.fromDateTime(local).format(context);
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return clock;
  }
  return '${local.day} ${_months[local.month - 1]}, $clock';
}

bool _isStale(DateTime time) =>
    DateTime.now().difference(time) > const Duration(hours: 12);

String _pinWord(MapPinUpdate pin) => switch ((pin.category, pin.status)) {
  ('flood', 'F') => 'Flooding',
  ('flood', 'W') => 'On watch',
  ('flood', 'C') => 'Clear',
  ('road', 'X') => 'Closed',
  ('road', 'L') => 'Light vehicles only',
  ('road', 'O') => 'Open',
  ('evacuation', 'F') => 'Full',
  ('evacuation', 'X') => 'Closed',
  ('evacuation', 'O') => 'Open',
  _ => pin.status,
};

/// Pin color follows its status word, so the color always matches the text.
Color _pinStatusColor(MapPinUpdate pin) => switch ((pin.category, pin.status)) {
  ('flood', 'F') ||
  ('road', 'X') ||
  ('evacuation', 'F') ||
  ('evacuation', 'X') => NimbusColors.danger,
  ('flood', 'W') || ('road', 'L') => NimbusColors.warning,
  ('evacuation', _) when pin.intensity >= 85 => NimbusColors.warning,
  _ => NimbusColors.ok,
};

_Row _pinRow(MapPinUpdate pin, String tag) => _Row(
  Icons.location_on_outlined,
  _pinStatusColor(pin),
  tag,
  pin.label,
  pin.category == 'evacuation' ? '' : pinAmountText(pin),
  status: _pinWord(pin),
  percent: pin.category == 'evacuation' ? pin.intensity : null,
);

/// One-line verdict for the Overview digest.
typedef _Count = ({IconData icon, String count, _Sev sev, String label});

({_Sev sev, String headline, String detail, List<_Count> counts}) _digest(
  LguUpdate update,
  String town,
  String when,
) {
  // Map pins count as places too (an LGU may only drop pins), unless they repeat a
  // place already in the lists.
  final listed = {
    for (final a in update.floodAreas) a.name.trim().toLowerCase(),
    for (final c in update.evacuationCenters) c.name.trim().toLowerCase(),
    for (final r in update.roadStatuses) r.name.trim().toLowerCase(),
  };
  final pins = [
    for (final p in update.mapPins)
      if (!listed.contains(p.label.trim().toLowerCase())) p,
  ];
  final u = LguUpdate(
    townCode: update.townCode,
    classes: update.classes,
    notice: update.notice,
    updatedAt: update.updatedAt,
    floodAreas: [
      ...update.floodAreas,
      for (final p in pins)
        if (p.category == 'flood') FloodAreaUpdate(name: p.label, level: 'M', status: p.status),
    ],
    evacuationCenters: [
      ...update.evacuationCenters,
      for (final p in pins)
        if (p.category == 'evacuation')
          EvacuationCenterUpdate(name: p.label, status: p.status, percentFull: p.intensity),
    ],
    roadStatuses: [
      ...update.roadStatuses,
      for (final p in pins)
        if (p.category == 'road') RoadStatusUpdate(name: p.label, status: p.status),
    ],
  );
  if (u.floodAreas.isEmpty &&
      u.evacuationCenters.isEmpty &&
      u.roadStatuses.isEmpty &&
      u.classes == 0 &&
      u.notice.trim().isEmpty) {
    return (
      sev: _Sev.neutral,
      headline: '$town LGU report has no area details',
      detail: 'Updated $when',
      counts: const <_Count>[],
    );
  }
  int count<T>(List<T> xs, bool Function(T) test) => xs.where(test).length;
  final flooding = count(u.floodAreas, (a) => a.status == 'F');
  final watch = count(u.floodAreas, (a) => a.status == 'W');
  final roadsClosed = count(u.roadStatuses, (r) => r.status == 'X');
  final roadsLight = count(u.roadStatuses, (r) => r.status == 'L');
  final evacFull = count(u.evacuationCenters, (c) => c.status == 'F');
  final evacClosed = count(u.evacuationCenters, (c) => c.status == 'X');
  final evacAlmost = count(
    u.evacuationCenters,
    (c) => c.status != 'F' && c.status != 'X' && c.percentFull >= 85,
  );

  final danger = [
    if (flooding > 0) 'Flooding in ${_plural(flooding, 'area', 'areas')}',
    if (roadsClosed > 0) '${_plural(roadsClosed, 'road', 'roads')} closed',
    if (evacFull > 0)
      '${_plural(evacFull, 'evacuation center', 'evacuation centers')} full',
    if (evacClosed > 0)
      '${_plural(evacClosed, 'evacuation center', 'evacuation centers')} closed',
  ];
  final warning = [
    if (u.classes > 0) 'Classes suspended',
    if (watch > 0) '${_plural(watch, 'area', 'areas')} on flood watch',
    if (roadsLight > 0)
      '${_plural(roadsLight, 'road', 'roads')} for light vehicles only',
    if (evacAlmost > 0)
      '${_plural(evacAlmost, 'evacuation center', 'evacuation centers')} almost full',
  ];
  final issues = [...danger, ...warning];
  if (issues.isEmpty) {
    return (
      sev: _Sev.ok,
      headline: 'No alerts from $town LGU',
      detail: 'Updated $when',
      counts: const <_Count>[],
    );
  }
  final evacOut = evacFull + evacClosed;
  final counts = <_Count>[
    if (flooding > 0)
      (
        icon: Icons.waves,
        count: '$flooding',
        sev: _Sev.danger,
        label: '$flooding flooding',
      ),
    if (roadsClosed > 0)
      (
        icon: Icons.block_rounded,
        count: '$roadsClosed',
        sev: _Sev.danger,
        label: '$roadsClosed roads closed',
      ),
    if (evacOut > 0)
      (
        icon: Icons.home_outlined,
        count: '$evacOut',
        sev: _Sev.danger,
        label: '$evacOut evacuation centers full or closed',
      ),
    if (watch > 0)
      (
        icon: Icons.waves,
        count: '$watch',
        sev: _Sev.warning,
        label: '$watch on flood watch',
      ),
    if (roadsLight > 0)
      (
        icon: Icons.add_road,
        count: '$roadsLight',
        sev: _Sev.warning,
        label: '$roadsLight roads light vehicles only',
      ),
    if (evacAlmost > 0)
      (
        icon: Icons.home_outlined,
        count: '$evacAlmost',
        sev: _Sev.warning,
        label: '$evacAlmost evacuation centers almost full',
      ),
    if (u.classes > 0)
      (
        icon: Icons.school_outlined,
        count: '',
        sev: _Sev.warning,
        label: 'classes suspended',
      ),
  ];
  return (
    sev: danger.isNotEmpty ? _Sev.danger : _Sev.warning,
    headline: issues.take(2).join(' · '),
    detail: '',
    counts: counts,
  );
}

// ---------------------------------------------------------------------------
// Bottom sheet
// ---------------------------------------------------------------------------

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.scroll,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onDragPanel,
    required this.onDragPanelEnd,
    required this.selected,
    required this.title,
    required this.cta,
    required this.location,
    required this.locations,
    required this.onLocation,
    required this.showSaved,
    required this.onPane,
    required this.saved,
    required this.onOpenSaved,
    required this.waiting,
    required this.latest,
    required this.reply,
    required this.publishedUpdate,
    required this.smsPins,
    required this.smsPinSnapshotReceived,
    required this.weatherFallback,
    required this.weatherFallbackLoading,
    required this.weatherFallbackError,
    required this.apiLoading,
    required this.apiError,
    required this.onRefreshApi,
    required this.onAsk,
  });

  final ScrollController scroll;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<double> onDragPanel;
  final ValueChanged<double> onDragPanelEnd;
  final String selected;
  final String title;
  final String cta;
  final PhilippineLocation location;
  final List<PhilippineLocation> locations;
  final ValueChanged<PhilippineLocation> onLocation;
  final bool showSaved;
  final ValueChanged<bool> onPane;
  final List<SavedUpdate> saved;
  final ValueChanged<SavedUpdate> onOpenSaved;
  final bool waiting;
  final SavedUpdate? latest;
  final codec.Reply? reply;
  final LguUpdate? publishedUpdate;
  final List<MapPinUpdate> smsPins;
  final bool smsPinSnapshotReceived;
  final WeatherSnapshot? weatherFallback;
  final bool weatherFallbackLoading;
  final String? weatherFallbackError;
  final bool apiLoading;
  final String? apiError;
  final VoidCallback onRefreshApi;
  final VoidCallback? onAsk;

  bool get _isOverview => selected == 'O';

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    final update = publishedUpdate;
    final showAdvisory =
        _isOverview &&
        update != null &&
        update.notice.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: NimbusColors.primary.withValues(alpha: 0.12),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      // While the sheet is dragged down it is still "expanded" until it
      // snaps, so only show the SMS footer when it actually fits.
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleExpanded,
              onVerticalDragUpdate: (d) => onDragPanel(d.delta.dy),
              onVerticalDragEnd: (d) => onDragPanelEnd(d.velocity.pixelsPerSecond.dy),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Column(
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: palette.line,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _isOverview ? location.name : title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_up,
                          size: 24,
                          color: palette.muted,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                children: [
                  if (!expanded)
                    if (_isOverview)
                      _overviewDigest(context, collapsed: true)
                    else
                      InkWell(
                        onTap: onToggleExpanded,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'Tap or swipe up for details',
                            style: TextStyle(fontSize: 14, color: palette.muted),
                          ),
                        ),
                      ),
                  if (expanded) ...[
                    if (_isOverview) ...[
                      _overviewDigest(context, collapsed: false),
                      if (showAdvisory) ...[
                        const SizedBox(height: 12),
                        _Advisory(town: location.name, notice: update.notice),
                      ],
                      const SizedBox(height: 12),
                    ] else
                      const SizedBox(height: 8),
                    _publishedContent(context),
                    const _SectionHeader(
                      icon: Icons.sms_outlined,
                      title: 'Updates by SMS',
                    ),
                    SegmentedButton<bool>(
                      segments: [
                        const ButtonSegment(
                          value: false,
                          label: Text('Latest'),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(
                            saved.isEmpty ? 'Saved' : 'Saved (${saved.length})',
                          ),
                        ),
                      ],
                      selected: {showSaved},
                      onSelectionChanged: (s) => onPane(s.first),
                      style: const ButtonStyle(
                        minimumSize: WidgetStatePropertyAll(
                          Size.fromHeight(NimbusSizes.minTap),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._content(context),
                  ],
                ],
              ),
            ),
            if (expanded && constraints.maxHeight >= 240)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: palette.line)),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tooltip(
                        message: 'Sends one text. No mobile data used.',
                        child: FilledButton.icon(
                          onPressed: onAsk,
                          icon: const Icon(Icons.sms_outlined),
                          label: Text(cta),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _overviewDigest(BuildContext context, {required bool collapsed}) {
    final onTap = collapsed ? onToggleExpanded : null;
    final error = apiError;
    if (error != null && publishedUpdate == null) {
      final sms = latest;
      final hasSms = sms != null && sms.townCode == location.smsCode;
      return _Digest(
        sev: hasSms ? _Sev.neutral : _Sev.warning,
        icon: hasSms ? Icons.sms_outlined : Icons.cloud_off_outlined,
        headline: hasSms
            ? 'Offline · showing the SMS update'
            : 'Can’t reach the LGU right now',
        detail: hasSms
            ? 'The latest LGU update arrived by SMS. See below.'
            : 'Check your signal, or get the storm update by SMS below.',
        collapsed: collapsed,
        onTap: onTap,
        action: TextButton(
          onPressed: onRefreshApi,
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          child: const Text('Retry'),
        ),
      );
    }
    final update = publishedUpdate;
    if (apiLoading && update == null) {
      return _Digest(
        sev: _Sev.neutral,
        leading: const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        headline: 'Checking ${location.name} LGU…',
        detail: '',
        collapsed: collapsed,
        onTap: onTap,
      );
    }
    if (update == null) {
      return _Digest(
        sev: _Sev.neutral,
        icon: Icons.info_outline,
        headline: 'No LGU report for ${location.name} yet',
        detail: 'Get the storm update by SMS below.',
        collapsed: collapsed,
        onTap: onTap,
      );
    }
    final d = _digest(
      update,
      location.name,
      _whenText(context, update.updatedAt),
    );
    return _Digest(
      sev: d.sev,
      headline: d.headline,
      detail: d.detail,
      counts: d.counts,
      collapsed: collapsed,
      onTap: onTap,
    );
  }

  Widget _publishedContent(BuildContext context) {
    if (selected == 'Q') return const SizedBox.shrink();

    if (selected == 'P') {
      final pins = publishedUpdate != null
          ? publishedUpdate!.mapPins
          : apiLoading || apiError != null
          ? (smsPinSnapshotReceived ? smsPins : const <MapPinUpdate>[])
          : const <MapPinUpdate>[];
      if (pins.isEmpty) {
        return const Padding(
          padding: EdgeInsets.only(top: 12),
          child: _Empty(
            'No map pins in the latest snapshot',
            'Tap a pin on the map for its status, or request the latest snapshot by SMS.',
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (publishedUpdate != null)
            _MetaRow(
              town: location.name,
              updatedAt: publishedUpdate!.updatedAt,
              onRefresh: onRefreshApi,
            ),
          _SectionHeader(
            icon: Icons.location_on_outlined,
            title: 'Map pins',
            summary: _plural(pins.length, 'pin', 'pins'),
          ),
          _Group([
            for (final pin in pins)
              _pinRow(pin, switch (pin.category) {
                'flood' => 'Flood pin',
                'evacuation' => 'Evacuation pin',
                _ => 'Road pin',
              }),
          ]),
        ],
      );
    }

    if (apiLoading && publishedUpdate == null) {
      if (_isOverview) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _Status(
          'Loading live LGU update…',
          context.nimbusPalette.muted,
          spinner: true,
        ),
      );
    }
    final error = apiError;
    if (error != null && publishedUpdate == null) {
      if (_isOverview) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _LguError(error: error, onRetry: onRefreshApi),
      );
    }
    final update = publishedUpdate;
    if (update == null) {
      if (_isOverview) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _Empty(
          'No $_selectedLabel report',
          'No status has been published for ${location.name}.',
        ),
      );
    }

    bool shows(String tab) => _isOverview || selected == tab;

    // Pins that repeat a listed place add nothing; keep only the new ones.
    final listedNames = {
      for (final a in update.floodAreas) _norm(a.name),
      for (final c in update.evacuationCenters) _norm(c.name),
      for (final r in update.roadStatuses) _norm(r.name),
    };
    final extraPins = [
      for (final pin in update.mapPins)
        if (!listedNames.contains(_norm(pin.label))) pin,
    ];
    List<Widget> pinRows(String category) => [
      for (final pin in extraPins.where((p) => p.category == category))
        _pinRow(pin, 'Map pin'),
    ];

    final sections = <Widget>[];

    if (shows('F')) {
      final areas = _stableSort(update.floodAreas, _floodRank);
      final rows = <Widget>[
        for (final area in areas)
          _Row(
            Icons.waves,
            switch (area.status) {
              'F' => NimbusColors.danger,
              'W' => NimbusColors.warning,
              _ => NimbusColors.ok,
            },
            area.status == 'W' ? 'Water rising nearby' : '',
            area.name,
            switch (area.level) {
              'H' => 'High risk area',
              'M' => 'Medium risk area',
              'L' => 'Low risk area',
              _ => '',
            },
            status: switch (area.status) {
              'F' => 'Flooding now',
              'W' => 'On watch',
              _ => 'No flooding',
            },
          ),
        ...pinRows('flood'),
      ];
      if (rows.isNotEmpty) {
        final flooding = areas.where((a) => a.status == 'F').length;
        final watch = areas.where((a) => a.status == 'W').length;
        final clear = areas.length - flooding - watch;
        sections.addAll([
          _SectionHeader(
            icon: Icons.waves,
            title: 'Flood areas',
            summary: areas.isEmpty
                ? null
                : flooding == 0 && watch == 0
                ? 'All clear'
                : [
                    if (flooding > 0) '$flooding flooding',
                    if (watch > 0) '$watch on watch',
                    if (clear > 0) '$clear clear',
                  ].join(' · '),
          ),
          _Group(rows),
        ]);
      }
    }

    if (shows('E')) {
      final centers = _stableSort(update.evacuationCenters, _evacRank);
      final rows = <Widget>[
        for (final center in centers)
          _Row(
            Icons.home_outlined,
            center.status == 'F' || center.status == 'X'
                ? NimbusColors.danger
                : center.percentFull >= 85
                ? NimbusColors.warning
                : NimbusColors.ok,
            '',
            center.name,
            switch (center.status) {
              'F' => 'Go to another center',
              'X' => 'Not taking evacuees',
              _ => '',
            },
            status: switch (center.status) {
              'F' => 'Full',
              'X' => 'Closed',
              _ when center.percentFull >= 85 => 'Almost full',
              _ => 'Open',
            },
            percent: center.status == 'X' ? null : center.percentFull,
          ),
        ...pinRows('evacuation'),
      ];
      if (rows.isNotEmpty) {
        final full = centers.where((c) => c.status == 'F').length;
        final closed = centers.where((c) => c.status == 'X').length;
        final open = centers.length - full - closed;
        sections.addAll([
          _SectionHeader(
            icon: Icons.home_outlined,
            title: 'Evacuation centers',
            summary: centers.isEmpty
                ? null
                : full == 0 && closed == 0
                ? 'All open'
                : [
                    if (full > 0) '$full full',
                    if (closed > 0) '$closed closed',
                    if (open > 0) '$open open',
                  ].join(' · '),
          ),
          _Group(rows),
        ]);
      }
    }

    if (shows('R')) {
      final roads = _stableSort(update.roadStatuses, _roadRank);
      final rows = <Widget>[
        for (final road in roads)
          _Row(
            Icons.add_road,
            {
                  'X': NimbusColors.danger,
                  'L': NimbusColors.warning,
                }[road.status] ??
                NimbusColors.ok,
            '',
            road.name,
            (_road[road.status] ?? ('Unknown', '')).$2,
            status: (_road[road.status] ?? ('Unknown', '')).$1,
          ),
        ...pinRows('road'),
      ];
      if (rows.isNotEmpty) {
        final closed = roads.where((r) => r.status == 'X').length;
        final light = roads.where((r) => r.status == 'L').length;
        final open = roads.length - closed - light;
        sections.addAll([
          _SectionHeader(
            icon: Icons.add_road,
            title: 'Roads',
            summary: roads.isEmpty
                ? null
                : closed == 0 && light == 0
                ? 'All open'
                : [
                    if (closed > 0) '$closed closed',
                    if (light > 0) '$light light vehicles only',
                    if (open > 0) '$open open',
                  ].join(' · '),
          ),
          _Group(rows),
        ]);
      }
    }

    if (shows('C')) {
      sections.addAll([
        const _SectionHeader(icon: Icons.school_outlined, title: 'Classes'),
        _Group([_classesRow(update.classes)]),
      ]);
    }

    if (!_isOverview && sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _Empty(
          'No $_selectedLabel status',
          'No ${_selectedLabel.toLowerCase()} status has been included in the latest LGU report.',
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The Overview summary card already says "Updated …".
        if (!_isOverview)
          _MetaRow(
            town: location.name,
            updatedAt: update.updatedAt,
            onRefresh: onRefreshApi,
          ),
        ...sections,
      ],
    );
  }

  String get _selectedLabel => switch (selected) {
    'F' => 'Flood',
    'E' => 'Evacuation',
    'C' => 'Class',
    'R' => 'Road',
    _ => 'LGU',
  };

  PhilippineLocation? _findLocation(String code) {
    for (final candidate in locations) {
      if (candidate.code == code || candidate.smsCode == code) return candidate;
    }
    return null;
  }

  String _locationName(String code) =>
      _findLocation(code)?.name ??
      townByCodeOrNull(code)?.name ??
      'Unknown location ($code)';

  Town _townForReply(String code) {
    final match = _findLocation(code);
    if (match != null) return townForLocation(match);
    return townByCodeOrNull(code) ?? townForLocation(location);
  }

  /// A saved SMS reply as short plain-text bullets.
  List<String> _savedBullets(SavedUpdate u) {
    final r = codec.decode(u.sms);
    if (r == null) return [u.sms];
    String name(codec.Item i, String kind) => i.customName ?? '$kind ${i.index}';
    final out = <String>[];
    switch (r.type) {
      case 'Q':
        final s = r.storm!;
        final w = int.tryParse(s.warning) ?? 0;
        out.add(w > 0 ? 'Wind signal No. $w' : 'No wind signal');
        if (s.classes > 0) out.add('Classes suspended (level ${s.classes})');
        var text = r.notice;
        for (final marker in [' Do: ', 'Wx: ', 'River: ']) {
          text = text.replaceAll(marker, '\n${marker.trim()} ');
        }
        out.addAll(text.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty)
            .map((x) => x.startsWith('Wx:') ? 'Weather: ${x.substring(3).trim()}' : x));
      case 'F':
        for (final i in r.items) {
          out.add('${name(i, 'Area')}: ${switch (i.now) { 'F' => 'flooding now', 'W' => 'on watch', _ => 'no flooding' }}');
        }
      case 'E':
        for (final i in r.items) {
          out.add('${name(i, 'Site')}: ${switch (i.status) { 'F' => 'full', 'X' => 'closed', _ => 'open, ${i.percentFull ?? 0}% full' }}');
        }
      case 'R':
        for (final i in r.items) {
          out.add('${name(i, 'Road')}: ${switch (i.status) { 'X' => 'closed', 'L' => 'light vehicles only', _ => 'open' }}');
        }
      case 'P':
        for (final pin in r.pins) {
          final m = MapPinUpdate(category: pin.category, label: pin.label, latitude: pin.latitude,
              longitude: pin.longitude, status: pin.status, intensity: pin.intensity);
          out.add('${pin.label}: ${_pinWord(m).toLowerCase()} · ${pinAmountText(m)}');
        }
    }
    if (out.isEmpty) out.add('Nothing reported');
    if (!r.valid) out.add('Not verified');
    return out;
  }

  List<Widget> _content(BuildContext context) {
    if (showSaved) {
      if (saved.isEmpty) {
        return [
          const _Empty(
            'No saved updates yet',
            'Every reply you get is saved here automatically.',
          ),
        ];
      }
      return [
        // Saved records open in place as plain bullets; the Latest tab is left alone.
        for (final u in saved)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_r),
                  side: BorderSide(color: context.nimbusPalette.line),
                ),
                collapsedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_r),
                  side: BorderSide(color: context.nimbusPalette.line),
                ),
                title: Text(
                  '${_tabs.firstWhere((t) => t.$1 == u.type, orElse: () => _tabs.first).$4} · ${_locationName(u.townCode)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('Received ${_whenText(context, u.received)}'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in _savedBullets(u))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('•  $line', style: const TextStyle(fontSize: 14)),
                    ),
                ],
              ),
            ),
          ),
      ];
    }
    final out = <Widget>[];
    // The SMS reply already carries Open-Meteo weather ("Wx: ..."), so only show the
    // app's own online lookup when it worked, or when there's no SMS weather to fall back on.
    final smsHasWeather = reply?.type == 'Q' && reply!.notice.contains('Wx: ');
    if ((selected == 'O' || selected == 'Q') &&
        (weatherFallback != null ||
            (!smsHasWeather &&
                (weatherFallbackLoading || weatherFallbackError != null)))) {
      out.add(
        _WeatherFallback(
          snapshot: weatherFallback,
          loading: weatherFallbackLoading,
          error: weatherFallbackError,
        ),
      );
    }
    if (waiting) {
      out.add(
        _Status(
          'Waiting for reply by SMS…',
          context.nimbusPalette.muted,
          spinner: true,
        ),
      );
    }
    final r = reply;
    if (r == null) {
      if (!waiting) {
        out.add(
          _Empty(
            weatherFallback == null
                ? 'Not requested yet'
                : 'No fresh storm SMS reply',
            weatherFallback == null
                ? 'Tap “$cta”. The reply is saved here so you can open it again offline.'
                : 'Open-Meteo is general local weather, not an official storm warning.',
          ),
        );
      }
      return out;
    }
    final t = _townForReply(r.townCode);
    final issued = 'Issued ${r.time.substring(0, 2)}:${r.time.substring(2)}';
    if (selected == 'C' && r.type == 'Q') {
      out
        ..add(_ReplyMeta(issued: issued, valid: r.valid))
        ..add(_Group([_classesRow(r.storm!.classes)]));
      return out;
    }
    final rows = <Widget>[];
    var numbered = false;
    var showBulletin = false;
    Widget? signalCard; // wind signal gets its own card above the storm details
    switch (r.type) {
      case 'Q':
        final s = r.storm!;
        // Relay appends Open-Meteo local weather as "Wx: ..." at the end.
        final wxAt = r.notice.indexOf('Wx: ');
        final wxAll = wxAt >= 0 ? r.notice.substring(wxAt + 4).trim() : '';
        final riverAt = wxAll.indexOf('River: ');
        final weather = riverAt >= 0 ? wxAll.substring(0, riverAt).trim() : wxAll;
        final river = riverAt >= 0 ? wxAll.substring(riverAt + 7).trim() : '';
        final notice = wxAt >= 0 ? r.notice.substring(0, wxAt).trim() : r.notice;
        final noStormAt = notice.toLowerCase().indexOf('no current storm');
        if (noStormAt >= 0) {
          // The relay puts the LGU advisory before the PAGASA "no storm" line.
          final lguNotice = notice.substring(0, noStormAt).trim();
          if (lguNotice.isNotEmpty) {
            rows.add(
              _Row(Icons.campaign_outlined, NimbusColors.primary, 'LGU',
                  lguNotice, ''),
            );
          }
          if (s.classes > 0) rows.add(_classesRow(s.classes));
          rows.add(
            _Row(
              Icons.cloud_off_outlined,
              NimbusColors.ok,
              '', // the sentence already says "administered by PAGASA"
              notice.substring(noStormAt).trim(),
              '',
            ),
          );
        } else {
          // Relay format: [LGU advisory.] [DRILL] <storm line>. Do: <advice>
          final drill = notice.contains('DRILL ');
          final doAt = notice.indexOf(' Do: ');
          final advice = doAt >= 0 ? notice.substring(doAt + 5).trim() : '';
          final storm = (doAt >= 0 ? notice.substring(0, doAt) : notice)
              .replaceFirst('DRILL ', '')
              .trim();
          final signal = int.tryParse(s.warning) ?? 0;
          if (drill) {
            showBulletin = true;
            rows.add(
              _Row(
                Icons.science_outlined,
                NimbusColors.warning,
                'DRILL',
                'Practice storm: replayed PAGASA bulletin',
                '',
              ),
            );
          }
          signalCard = _Group([
            _Row(
              Icons.air,
              signal >= 3
                  ? NimbusColors.danger
                  : signal >= 1
                  ? NimbusColors.warning
                  : NimbusColors.ok,
              'Wind signal for ${t.name}',
              signal > 0 ? 'Signal No. $signal' : 'No wind signal',
              '',
              status: switch (signal) {
                1 => 'Strong winds 39-61 km/h',
                2 => 'Gale-force winds 62-88 km/h',
                3 => 'Storm-force winds 89-117 km/h',
                4 => 'Typhoon-force winds 118-184 km/h',
                5 => 'Extreme winds 185+ km/h',
                _ => 'Not under a PAGASA wind signal',
              },
            ),
          ]);
          rows.add(
            _Row(
              Icons.cyclone,
              NimbusColors.primary,
              'PAGASA bulletin',
              storm.isEmpty ? 'PAGASA bulletin received' : storm,
              '',
            ),
          );
          if (advice.isNotEmpty) {
            rows.add(
              _Row(
                Icons.checklist,
                NimbusColors.primary,
                'What to do',
                advice,
                '',
              ),
            );
          }
          rows.add(
              _Row(
                Icons.cloud_outlined,
                NimbusColors.primary,
                'Forecast for ${t.name}',
                '${_rain[s.rain.clamp(0, 4)]}, gusts ${s.gusts} km/h',
                '',
              ),
            );
        }
        if (weather.isNotEmpty) {
          rows.add(
            _Row(
              Icons.thermostat_outlined,
              NimbusColors.primary,
              'Local weather · Open-Meteo, not a PAGASA warning',
              weather,
              '',
            ),
          );
        }
        if (river.isNotEmpty) {
          rows.add(
            _Row(
              Icons.water_outlined,
              NimbusColors.warning,
              'River forecast · GloFAS via Open-Meteo',
              river[0].toUpperCase() + river.substring(1),
              '',
            ),
          );
        }
        break;
      case 'F':
        numbered = true;
        for (final i in r.items) {
          final name =
              i.customName ??
              (i.index <= t.floodAreas.length
                  ? t.floodAreas[i.index - 1]
                  : 'Area ${i.index}');
          final color =
              {'F': NimbusColors.danger, 'W': NimbusColors.warning}[i.now] ??
              NimbusColors.ok;
          rows.add(
            _Row(
              null,
              color,
              _level[i.level] ?? '',
              name,
              '',
              number: i.index,
              status: switch (i.now) {
                'F' => 'Flooding now',
                'W' => 'On watch',
                _ => 'No flooding',
              },
            ),
          );
        }
        break;
      case 'E':
        numbered = true;
        for (final i in r.items) {
          final name =
              i.customName ??
              (i.index <= t.sites.length
                  ? t.sites[i.index - 1]
                  : 'Site ${i.index}');
          final pct = i.percentFull ?? 0;
          rows.add(switch (i.status) {
            'F' => _Row(
              null,
              NimbusColors.danger,
              '',
              name,
              'No room left, go to another site',
              number: i.index,
              percent: 100,
              status: 'Full',
            ),
            'X' => _Row(
              null,
              context.nimbusPalette.muted,
              '',
              name,
              'Not taking evacuees',
              number: i.index,
              status: 'Closed',
            ),
            _ => _Row(
              null,
              pct >= 85 ? NimbusColors.warning : NimbusColors.ok,
              '',
              name,
              '',
              number: i.index,
              percent: pct,
              status: pct >= 85 ? 'Almost full' : 'Open',
            ),
          });
        }
        break;
      case 'R':
        numbered = true;
        for (final i in r.items) {
          final name =
              i.customName ??
              (i.index <= t.roads.length
                  ? t.roads[i.index - 1]
                  : 'Road ${i.index}');
          final s = _road[i.status] ?? ('', '');
          final color =
              {'X': NimbusColors.danger, 'L': NimbusColors.warning}[i.status] ??
              NimbusColors.ok;
          rows.add(
            _Row(
              null,
              color,
              '',
              name,
              s.$2,
              number: i.index,
              status: s.$1.isEmpty ? null : s.$1,
            ),
          );
        }
    }
    out.add(_ReplyMeta(issued: issued, valid: r.valid));
    if (signalCard != null) out..add(signalCard)..add(const SizedBox(height: 10));
    if (rows.isNotEmpty) out.add(_Group(rows, indent: numbered ? 54 : 48));
    if (showBulletin) {
      out.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const _BulletinViewer()),
            ),
            icon: const Icon(Icons.description_outlined),
            label: const Text('View PAGASA bulletin (needs internet)'),
          ),
        ),
      );
    }
    return out;
  }
}

_Row _classesRow(int classes) => _Row(
  Icons.school_outlined,
  classes == 0 ? NimbusColors.ok : NimbusColors.warning,
  '',
  classes == 0 ? 'Classes as usual' : 'Classes suspended',
  '',
  status: classes == 0 ? 'No suspension' : _classes[classes.clamp(0, 5)],
);

// ---------------------------------------------------------------------------
// Sheet building blocks
// ---------------------------------------------------------------------------

class _Digest extends StatelessWidget {
  const _Digest({
    required this.sev,
    required this.headline,
    required this.detail,
    required this.collapsed,
    this.icon,
    this.leading,
    this.onTap,
    this.action,
    this.counts = const [],
  });

  final List<_Count> counts;
  final _Sev sev;
  final IconData? icon;
  final Widget? leading;
  final String headline;
  final String detail;
  final bool collapsed;
  final VoidCallback? onTap;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    final dark = _isDark(context);
    final neutral = sev == _Sev.neutral;
    final color = _sevColor(context, sev);
    final card = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: neutral
            ? palette.surfaceAlt
            : Color.alphaBlend(
                color.withValues(alpha: dark ? 0.18 : 0.08),
                palette.surface,
              ),
        borderRadius: BorderRadius.circular(_r),
        border: Border.all(
          color: neutral ? palette.line : color.withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: neutral
                  ? palette.surface
                  : color.withValues(alpha: dark ? 0.28 : 0.16),
            ),
            child:
                leading ?? Icon(icon ?? _sevIcon(sev), size: 22, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  maxLines: collapsed ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                if (counts.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _CountRow(counts: counts, collapsed: collapsed),
                ],
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: collapsed ? 1 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                      color: palette.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
    final sevWord = switch (sev) {
      _Sev.danger => 'Danger',
      _Sev.warning => 'Caution',
      _Sev.ok => 'All clear',
      _Sev.neutral => 'Info',
    };
    return Semantics(
      container: true,
      label:
          'Status $sevWord. $headline. $detail '
          '${counts.map((c) => c.label).join(', ')}',
      excludeSemantics: action == null,
      child: onTap == null
          ? card
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(_r),
                child: card,
              ),
            ),
    );
  }
}

class _Advisory extends StatelessWidget {
  const _Advisory({required this.town, required this.notice});
  final String town;
  final String notice;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: palette.primarySoft,
        borderRadius: BorderRadius.circular(_r),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.campaign_outlined,
            size: 20,
            color: _isDark(context) ? NimbusColors.wind : NimbusColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    'Advisory from $town LGU',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: palette.text,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  notice,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    color: palette.text,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.town,
    required this.updatedAt,
    required this.onRefresh,
  });
  final String town;
  final DateTime updatedAt;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    final stale = _isStale(updatedAt);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: NimbusSizes.minTap),
        child: Row(
          children: [
            if (stale)
              const Tooltip(
                message: 'May be out of date',
                triggerMode: TooltipTriggerMode.tap,
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: NimbusColors.warning,
                  semanticLabel: 'May be out of date',
                ),
              )
            else
              Icon(Icons.update, size: 16, color: palette.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Updated ${_whenText(context, updatedAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: palette.muted,
                ),
              ),
            ),
            IconButton(
              onPressed: onRefresh,
              tooltip: 'Refresh town status',
              constraints: const BoxConstraints(
                minWidth: NimbusSizes.minTap,
                minHeight: NimbusSizes.minTap,
              ),
              icon: Icon(Icons.refresh, size: 20, color: palette.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title, this.summary});
  final IconData icon;
  final String title;
  final String? summary;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.muted),
          const SizedBox(width: 8),
          Semantics(
            header: true,
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: palette.text,
              ),
            ),
          ),
          // Rows are sorted worst-first, so the header only names the group;
          // `summary` stays available for screen readers.
          if (summary != null)
            Expanded(
              child: Semantics(label: summary, child: const SizedBox.shrink()),
            ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.rows, {this.indent = 14});
  final List<Widget> rows;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(_r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: palette.line,
                indent: indent,
              ),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row(
    this.icon,
    this.color,
    this.tag,
    this.big,
    this.sub, {
    this.number,
    this.percent,
    this.status,
  });
  final IconData? icon;
  final Color color;
  final String tag;
  final String big;
  final String sub;
  final int? number;
  final int? percent;

  /// Short status word ("Closed", "On watch"), shown with a shape icon.
  /// Rows with a status hide [tag]/[sub] until tapped.
  final String? status;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final palette = context.nimbusPalette;
    final dark = _isDark(context);
    final detail = [w.tag, w.sub].where((s) => s.isNotEmpty).join(' · ');
    final sev = _sevOfColor(w.color);
    final expandable = w.status != null && detail.isNotEmpty;

    Widget? leading;
    if (w.number != null) {
      leading = Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: w.color.withValues(alpha: dark ? 0.28 : 0.16),
        ),
        child: Text(
          '${w.number}',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: palette.text,
          ),
        ),
      );
    } else if (w.status == null && w.icon != null) {
      leading = Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(w.icon, size: 22, color: w.color),
      );
    }

    final body = Container(
      color: w.color == NimbusColors.danger
          ? w.color.withValues(alpha: dark ? 0.12 : 0.06)
          : null,
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) ...[leading, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.big,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    color: palette.text,
                  ),
                ),
                if (w.status != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        _sevIcon(sev, word: w.status),
                        size: 16,
                        color: sev == _Sev.neutral ? palette.muted : w.color,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          w.status!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: palette.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_open && detail.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.35,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ] else if (detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.35,
                      color: palette.muted,
                    ),
                  ),
                ],
                if (w.percent != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: w.percent! / 100,
                            minHeight: 6,
                            color: w.color,
                            backgroundColor: palette.line,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${w.percent}%',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: palette.muted,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (expandable) ...[
            const SizedBox(width: 8),
            Icon(
              _open ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: palette.muted,
            ),
          ],
        ],
      ),
    );

    if (!expandable) return MergeSemantics(child: body);
    return MergeSemantics(
      child: Semantics(
        button: true,
        expanded: _open,
        hint: _open ? null : detail,
        child: InkWell(
          onTap: () => setState(() => _open = !_open),
          child: body,
        ),
      ),
    );
  }
}

/// Small icon + number pills under the digest headline.
class _CountRow extends StatelessWidget {
  const _CountRow({required this.counts, required this.collapsed});
  final List<_Count> counts;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    final dark = _isDark(context);
    final shown = collapsed && counts.length > 4
        ? counts.take(4).toList()
        : counts;
    final more = counts.length - shown.length;
    Widget pill(_Count c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _sevColor(context, c.sev).withValues(alpha: dark ? 0.24 : 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(c.icon, size: 15, color: _sevColor(context, c.sev)),
          if (c.count.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              c.count,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: palette.text,
              ),
            ),
          ],
        ],
      ),
    );
    return ExcludeSemantics(
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final c in shown) pill(c),
          if (more > 0)
            Text(
              '+$more',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: palette.muted,
              ),
            ),
        ],
      ),
    );
  }
}

class _ReplyMeta extends StatelessWidget {
  const _ReplyMeta({required this.issued, required this.valid});
  final String issued;
  final bool valid;

  @override
  Widget build(BuildContext context) {
    if (!valid) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _SignatureLine(valid: false),
      );
    }
    final palette = context.nimbusPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
      child: Row(
        children: [
          Text(
            issued,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: palette.muted,
            ),
          ),
          const SizedBox(width: 6),
          const Tooltip(
            message: 'Verified: sent by NIMBUS',
            triggerMode: TooltipTriggerMode.tap,
            child: Icon(
              Icons.verified_outlined,
              size: 16,
              color: NimbusColors.ok,
              semanticLabel: 'Verified: sent by NIMBUS',
            ),
          ),
        ],
      ),
    );
  }
}

class _SignatureLine extends StatelessWidget {
  const _SignatureLine({required this.valid});
  final bool valid;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    final row = Row(
      children: [
        Icon(
          valid ? Icons.verified_outlined : Icons.gpp_bad_outlined,
          size: 16,
          color: valid ? NimbusColors.ok : NimbusColors.danger,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            valid
                ? 'Verified: sent by NIMBUS'
                : 'Not verified. Don’t trust this reply.',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: valid ? FontWeight.w600 : FontWeight.w700,
              color: valid ? palette.muted : palette.text,
            ),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: valid
          ? row
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: NimbusColors.danger.withValues(
                  alpha: _isDark(context) ? 0.18 : 0.08,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: row,
            ),
    );
  }
}

class _LguError extends StatelessWidget {
  const _LguError({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
      decoration: BoxDecoration(
        color: NimbusColors.warning.withValues(
          alpha: _isDark(context) ? 0.20 : 0.10,
        ),
        borderRadius: BorderRadius.circular(_r),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 20,
            color: NimbusColors.warning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Can’t reach the LGU right now',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
                Text(
                  error,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: palette.muted),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onRetry,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _WeatherFallback extends StatelessWidget {
  const _WeatherFallback({
    required this.snapshot,
    required this.loading,
    required this.error,
  });

  final WeatherSnapshot? snapshot;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    final weather = snapshot;
    final muted = TextStyle(fontSize: 13.5, color: palette.muted);

    Widget metric(String label, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: palette.muted,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: palette.text,
            ),
          ),
        ],
      ),
    );

    final List<Widget> body;
    if (loading) {
      body = [
        const Text(
          'Weather now',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const LinearProgressIndicator(minHeight: 3),
        const SizedBox(height: 6),
        Text('Checking current conditions…', style: muted),
      ];
    } else if (error != null) {
      body = [
        Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 18, color: palette.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Weather not available right now',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
            ),
          ],
        ),
        Text(
          error!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: palette.muted),
        ),
      ];
    } else if (weather != null) {
      body = [
        Row(
          children: [
            const Icon(
              Icons.cloud_outlined,
              size: 28,
              color: NimbusColors.primary,
            ),
            const SizedBox(width: 12),
            Text(
              '${weather.temperatureC.round()}°C',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: palette.text,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    weather.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.text,
                    ),
                  ),
                  Text(
                    'Feels like ${weather.apparentTemperatureC.round()}°C',
                    style: TextStyle(fontSize: 13, color: palette.muted),
                  ),
                ],
              ),
            ),
            Tooltip(
              triggerMode: TooltipTriggerMode.tap,
              showDuration: const Duration(seconds: 5),
              message:
                  'Open-Meteo, observed '
                  '${TimeOfDay.fromDateTime(weather.observedAt.toLocal()).format(context)}. '
                  'General weather, not an official PAGASA warning.',
              child: SizedBox.square(
                dimension: NimbusSizes.minTap,
                child: Icon(Icons.info_outline, size: 20, color: palette.muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            metric('Wind', '${weather.windKph.round()} km/h'),
            metric('Gusts', '${weather.gustKph.round()} km/h'),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            metric(
              'Rain now',
              '${weather.precipitationMm.toStringAsFixed(1)} mm',
            ),
            metric('Humidity', '${weather.humidityPercent}%'),
          ],
        ),
      ];
    } else {
      body = const [];
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceAlt,
        borderRadius: BorderRadius.circular(_r),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: body,
      ),
    );
  }
}

class _Status extends StatelessWidget {
  // `color` is kept for existing callers; status text is always muted.
  const _Status(this.text, this.color, {this.spinner = false});
  final String text;
  final Color color;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(_r),
      ),
      child: Row(
        children: [
          if (spinner) ...[
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: palette.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.title, this.body);
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final palette = context.nimbusPalette;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(_r),
      ),
      child: Column(
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.4, color: palette.muted),
          ),
        ],
      ),
    );
  }
}


/// The PAGASA bulletin pages the current storm drill was parsed from.
class _BulletinViewer extends StatefulWidget {
  const _BulletinViewer();

  @override
  State<_BulletinViewer> createState() => _BulletinViewerState();
}

class _BulletinViewerState extends State<_BulletinViewer> {
  final _api = LguApiService().baseUri;
  late final Future<Map<String, dynamic>> _drill = _load();

  Future<Map<String, dynamic>> _load() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(_api.resolve('${_api.path}/drill'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PAGASA bulletin')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _drill,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final d = snap.data;
          final pages = (d?['pages'] as num?)?.toInt() ?? 0;
          if (snap.hasError || d == null || d['active'] != true || pages == 0) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'The bulletin can\'t be shown right now. It needs an internet '
                'connection and an active storm drill.',
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Text('${d['title']}', style: Theme.of(context).textTheme.titleMedium),
              Text('Issued ${d['issued']} · ${d['source']}',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              const Text('Pinch to zoom.'),
              const SizedBox(height: 8),
              for (var n = 1; n <= pages; n++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InteractiveViewer(
                    maxScale: 5,
                    child: Image.network(
                      _api.resolve('${_api.path}/drill/pages/$n').toString(),
                      loadingBuilder: (context, child, progress) => progress == null
                          ? child
                          : const SizedBox(height: 300, child: Center(child: CircularProgressIndicator())),
                      errorBuilder: (context, error, stack) =>
                          Text('Page $n could not load.'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
