import 'dart:async';

import 'package:flutter/material.dart';
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
    'Get storm update by SMS',
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
const _now = {
  'F': 'Flooding reported now',
  'W': 'On watch, water rising nearby',
  'C': 'No flooding now',
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
  Timer? _refreshTimer;
  bool _publishedUpdateLoaded = false;

  @override
  void initState() {
    super.initState();
    _panelController.addListener(_syncPanelExpanded);
    _location = widget.locations.first;
    _refreshPublishedUpdate(_location.code);
    _refreshSmsPins(_location.smsCode);
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _refreshPublishedUpdate(_location.code);
    });
    _sub = widget.sms.replies.listen((u) async {
      final saved = await widget.sms.saved();
      if (!mounted) return;
      final isCurrentStormReply =
          u.type == 'Q' &&
          u.townCode == _requestTownCode &&
          _requestStartedAt != null &&
          !u.received.isBefore(_requestStartedAt!);
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
          if (isCurrentStormReply) {
            _weatherFallbackTimer?.cancel();
            _weatherFallback = null;
            _weatherFallbackLoading = false;
            _weatherFallbackError = null;
          }
        }
      });
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
    super.dispose();
  }

  Future<void> _refreshPublishedUpdate(String townCode) async {
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
          : const [];

  void _onLocationChanged(
    PhilippineLocation location, {
    bool clearViewing = true,
  }) {
    _weatherFallbackTimer?.cancel();
    _weatherRequestId++;
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
        expanded ? 0.35 : 0.15,
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
      await widget.sms.ask(_smsType, _location.smsCode);
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message.toString())));
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
                              '${pin.category == 'evacuation' ? 'Occupancy' : 'Severity'}: ${pin.intensity}%',
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

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    final reply = latest == null ? null : codec.decode(latest.sms);
    final town = townForLocation(_location);
    final warning =
        town.warnings[reply?.storm?.warning ?? '2'] ?? ('Storm update', '');
    final activeTab = _tabs.firstWhere((tab) => tab.$1 == _tab);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: StormMap(
              location: _location,
              outline: widget.outline,
              floodReported:
                  _publishedUpdate?.floodAreas.any((a) => a.status == 'F') ??
                  false,
              mapPins: _mapPins,
              onPinTapped: _showMapPin,
              attributionBottomInset:
                  MediaQuery.sizeOf(context).height *
                      (_panelExpanded ? 0.35 : 0.15) +
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
            initialChildSize: 0.15,
            minChildSize: 0.15,
            maxChildSize: 0.85,
            snap: true,
            snapSizes: const [0.35],
            builder:
                (context, scroll) => _Sheet(
                  scroll: scroll,
                  expanded: _panelExpanded,
                  onToggleExpanded: _togglePanel,
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
                  publishedUpdate: _publishedUpdate,
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
  const _TopPill({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
    width: 240,
    decoration: _floating(context, 16),
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
        ),
      ],
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

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.scroll,
    required this.expanded,
    required this.onToggleExpanded,
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

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.nimbusPalette.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: NimbusColors.primary.withValues(alpha: 0.12),
            blurRadius: 30,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggleExpanded,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: context.nimbusPalette.line,
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Icon(
                        expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
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
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              children: [
                if (!expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Tap a category to view details',
                      style: TextStyle(color: context.nimbusPalette.muted),
                    ),
                  ),
                if (expanded) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Location',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  LocationPicker(
                    location: location,
                    locations: locations,
                    onSelected: onLocation,
                  ),
                  const SizedBox(height: 12),
                  _publishedContent(context),
                  const SizedBox(height: 10),
                  SegmentedButton<bool>(
                    segments: [
                      const ButtonSegment(value: false, label: Text('Latest')),
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
          if (expanded)
            Container(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: context.nimbusPalette.surfaceAlt),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: onAsk,
                      icon: const Icon(Icons.sms_outlined),
                      label: Text(cta),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'One tap sends one text. No mobile data used.',
                      style: TextStyle(
                        fontSize: 13,
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

  Widget _publishedContent(BuildContext context) {
    if (selected == 'P') {
      final pins =
          publishedUpdate != null
              ? publishedUpdate!.mapPins
              : apiLoading || apiError != null
              ? (smsPinSnapshotReceived ? smsPins : const <MapPinUpdate>[])
              : const <MapPinUpdate>[];
      if (pins.isEmpty) {
        return _Empty(
          'No map pins in the latest snapshot',
          'Tap a pin on the map for its status, or request the latest snapshot by SMS.',
        );
      }
      return Column(
        children: [
          for (final pin in pins)
            _Row(
              Icons.location_on_outlined,
              pin.intensity >= 70 ? NimbusColors.danger : NimbusColors.warning,
              switch (pin.category) {
                'flood' => 'Flood pin',
                'evacuation' => 'Evacuation pin',
                _ => 'Road pin',
              },
              pin.label,
              '${pin.status} · ${pin.intensity}%',
            ),
        ],
      );
    }
    if (selected == 'Q') return const SizedBox.shrink();
    if (apiLoading && publishedUpdate == null) {
      return _Status(
        'Loading live LGU update…',
        context.nimbusPalette.muted,
        spinner: true,
      );
    }
    final error = apiError;
    if (error != null) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.nimbusPalette.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Live LGU update unavailable: $error',
                style: const TextStyle(color: NimbusColors.danger),
              ),
            ),
            IconButton(
              onPressed: onRefreshApi,
              tooltip: 'Retry',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      );
    }

    final update = publishedUpdate;
    if (update == null) {
      return _Empty(
        selected == 'O'
            ? 'No current LGU report'
            : 'No ${_selectedLabel} report',
        'No status has been published for ${location.name}.',
      );
    }
    final when = TimeOfDay.fromDateTime(
      update.updatedAt.toLocal(),
    ).format(context);
    final out = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Latest LGU report',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
            ),
            Text(when, style: TextStyle(color: context.nimbusPalette.muted)),
            IconButton(
              onPressed: onRefreshApi,
              tooltip: 'Refresh town status',
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
    ];
    if (selected == 'O' || selected == 'C') {
      out.add(
        _Row(
          Icons.school_outlined,
          update.classes == 0 ? NimbusColors.ok : NimbusColors.warning,
          'Class status',
          update.classes == 0 ? 'No suspension' : 'Classes suspended',
          _classes[update.classes.clamp(0, 5)],
        ),
      );
    }
    if (selected == 'O' || selected == 'F') {
      for (final area in update.floodAreas) {
        final color =
            area.status == 'F'
                ? NimbusColors.danger
                : area.status == 'W'
                ? NimbusColors.warning
                : NimbusColors.ok;
        out.add(
          _Row(
            Icons.waves,
            color,
            '${_level[area.level] ?? 'Flood status'} · ${_now[area.status] ?? ''}',
            area.name,
            '',
          ),
        );
      }
    }
    if (selected == 'O' || selected == 'E') {
      for (final center in update.evacuationCenters) {
        final color =
            center.status == 'F' || center.status == 'X'
                ? NimbusColors.danger
                : center.percentFull >= 85
                ? NimbusColors.warning
                : NimbusColors.ok;
        final status = switch (center.status) {
          'F' => 'Full',
          'X' => 'Closed',
          _ => 'Open',
        };
        out.add(
          _Row(
            Icons.home_outlined,
            color,
            'Evacuation center · $status',
            center.name,
            '${center.percentFull}% full',
          ),
        );
      }
    }
    if ((selected == 'O') && update.notice.isNotEmpty) {
      out.add(
        _Row(
          Icons.campaign_outlined,
          NimbusColors.primary,
          'LGU advisory',
          update.notice,
          'From ${location.name} LGU',
        ),
      );
    }
    if (selected == 'O' || selected == 'R') {
      for (final road in update.roadStatuses) {
        final status = _road[road.status] ?? ('Unknown', '');
        final color =
            {'X': NimbusColors.danger, 'L': NimbusColors.warning}[road
                .status] ??
            NimbusColors.ok;
        out.add(
          _Row(
            Icons.add_road,
            color,
            'Road status · ${status.$1}',
            road.name,
            status.$2,
          ),
        );
      }
    }

    final mapPins = update.mapPins;
    if (selected == 'O') {
      for (final pin in mapPins) {
        out.add(
          _Row(
            Icons.location_on_outlined,
            pin.intensity >= 70 ? NimbusColors.danger : NimbusColors.warning,
            switch (pin.category) {
              'flood' => 'Flood pin',
              'evacuation' => 'Evacuation pin',
              _ => 'Road pin',
            },
            pin.label,
            '${pin.status} · ${pin.intensity}%',
          ),
        );
      }
    } else if (selected == 'F') {
      for (final pin in mapPins.where((pin) => pin.category == 'flood')) {
        out.add(
          _Row(
            Icons.waves,
            pin.intensity >= 70 ? NimbusColors.danger : NimbusColors.warning,
            'Flood pin',
            pin.label,
            '${pin.status} · ${pin.intensity}%',
          ),
        );
      }
    } else if (selected == 'E') {
      for (final pin in mapPins.where((pin) => pin.category == 'evacuation')) {
        out.add(
          _Row(
            Icons.home_outlined,
            NimbusColors.primary,
            'Evacuation pin',
            pin.label,
            '${pin.status} · ${pin.intensity}%',
          ),
        );
      }
    } else if (selected == 'R') {
      for (final pin in mapPins.where((pin) => pin.category == 'road')) {
        out.add(
          _Row(
            Icons.add_road,
            pin.status == 'X' ? NimbusColors.danger : NimbusColors.warning,
            'Road pin',
            pin.label,
            '${pin.status} · ${pin.intensity}%',
          ),
        );
      }
    }

    if (selected != 'O' && out.length == 1) {
      return _Empty(
        'No ${_selectedLabel} status',
        'No ${_selectedLabel.toLowerCase()} status has been included in the latest LGU report.',
      );
    }
    out.add(const SizedBox(height: 4));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: out,
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
        for (final u in saved)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              minTileHeight: 64,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: context.nimbusPalette.line),
              ),
              title: Text(
                '${_tabs.firstWhere((t) => t.$1 == u.type).$4} · ${_locationName(u.townCode)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                'Received ${TimeOfDay.fromDateTime(u.received).hour}:${u.received.minute.toString().padLeft(2, '0')}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpenSaved(u),
            ),
          ),
      ];
    }
    final out = <Widget>[];
    if ((selected == 'O' || selected == 'Q') &&
        (weatherFallback != null ||
            weatherFallbackLoading ||
            weatherFallbackError != null)) {
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
      final classes = r.storm!.classes;
      out
        ..add(
          _Row(
            Icons.school_outlined,
            classes == 0 ? NimbusColors.ok : NimbusColors.warning,
            'Class status',
            classes == 0 ? 'No suspension' : 'Classes suspended',
            _classes[classes.clamp(0, 5)],
          ),
        )
        ..add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              r.valid
                  ? '✓ Signature checked'
                  : '✕ Signature failed, don’t trust this reply',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: r.valid ? NimbusColors.ok : NimbusColors.danger,
              ),
            ),
          ),
        );
      return out;
    }
    switch (r.type) {
      case 'Q':
        final s = r.storm!;
        if (r.notice.isNotEmpty &&
            r.notice.toLowerCase().contains('no current storm')) {
          out.add(
            _Row(
              Icons.cloud_off_outlined,
              NimbusColors.ok,
              'PAGASA status',
              r.notice,
              '$issued · No active local warning from the latest PAGASA update',
            ),
          );
        } else {
          out.add(
            _Row(
              Icons.warning_amber,
              NimbusColors.danger,
              'PAGASA storm update',
              r.notice.isEmpty ? 'PAGASA bulletin received' : r.notice,
              '$issued · ${t.name}',
            ),
          );
          out.add(
            _Row(
              Icons.cloud_outlined,
              NimbusColors.primary,
              'Storm forecast',
              '${_rain[s.rain.clamp(0, 4)]}, gusts ${s.gusts} km/h',
              'Local municipality estimate',
            ),
          );
        }
        break;
      case 'F':
        for (final i in r.items) {
          final name =
              i.customName ??
              (i.index <= t.floodAreas.length
                  ? t.floodAreas[i.index - 1]
                  : 'Area ${i.index}');
          final color =
              {'H': NimbusColors.danger, 'M': NimbusColors.warning}[i.level] ??
              NimbusColors.ok;
          out.add(
            _Row(
              null,
              color,
              _level[i.level] ?? '',
              name,
              _now[i.now] ?? '',
              number: i.index,
            ),
          );
        }
        break;
      case 'E':
        for (final i in r.items) {
          final name =
              i.index <= t.sites.length
                  ? t.sites[i.index - 1]
                  : 'Site ${i.index}';
          final pct = i.percentFull ?? 0;
          out.add(switch (i.status) {
            'F' => _Row(
              null,
              NimbusColors.danger,
              'Full',
              name,
              'No room left, go to another site',
              number: i.index,
              percent: 100,
            ),
            'X' => _Row(
              null,
              context.nimbusPalette.muted,
              'Closed',
              name,
              'Not taking evacuees',
              number: i.index,
            ),
            _ => _Row(
              null,
              pct >= 85 ? NimbusColors.warning : NimbusColors.ok,
              pct >= 85 ? 'Almost full' : 'Open',
              name,
              '$pct% full',
              number: i.index,
              percent: pct,
            ),
          });
        }
        break;
      case 'R':
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
          out.add(_Row(null, color, s.$1, name, s.$2, number: i.index));
        }
    }
    out.add(
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          r.valid
              ? '✓ Signature checked'
              : '✕ Signature failed, don’t trust this reply',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: r.valid ? NimbusColors.ok : NimbusColors.danger,
          ),
        ),
      ),
    );
    return out;
  }
}

class _Row extends StatelessWidget {
  const _Row(
    this.icon,
    this.color,
    this.tag,
    this.big,
    this.sub, {
    this.number,
    this.percent,
  });
  final IconData? icon;
  final Color color;
  final String tag;
  final String big;
  final String sub;
  final int? number;
  final int? percent;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.nimbusPalette.surfaceAlt,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child:
              icon != null
                  ? Icon(icon, color: NimbusColors.onPrimary)
                  : Text(
                    '$number',
                    style: const TextStyle(
                      color: NimbusColors.onPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tag.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: context.nimbusPalette.muted,
                ),
              ),
              Text(
                big,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                sub,
                style: TextStyle(
                  fontSize: 13.5,
                  color: context.nimbusPalette.muted,
                ),
              ),
              if (percent != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: LinearProgressIndicator(
                      value: percent! / 100,
                      minHeight: 6,
                      color: color,
                      backgroundColor: context.nimbusPalette.surface,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
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
    final weather = snapshot;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: context.nimbusPalette.surfaceAlt,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Current local weather · Open-Meteo',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            const Text('General weather only — not an official storm warning.'),
            if (loading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
              const SizedBox(height: 6),
              const Text('Checking current conditions…'),
            ] else if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                'Weather fallback unavailable: $error',
                style: const TextStyle(color: NimbusColors.danger),
              ),
            ] else if (weather != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.cloud_outlined, color: NimbusColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${weather.description} · '
                      '${weather.temperatureC.round()}°C',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Feels like ${weather.apparentTemperatureC.round()}°C · '
                'Wind ${weather.windKph.round()} km/h · '
                'Gusts ${weather.gustKph.round()} km/h',
              ),
              Text(
                'Rain ${weather.precipitationMm.toStringAsFixed(1)} mm · '
                'Humidity ${weather.humidityPercent}%',
              ),
              Text(
                'Observed ${TimeOfDay.fromDateTime(weather.observedAt.toLocal()).format(context)}',
                style: TextStyle(color: context.nimbusPalette.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.text, this.color, {this.spinner = false});
  final String text;
  final Color color;
  final bool spinner;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.nimbusPalette.surfaceAlt,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        if (spinner)
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (spinner) const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.title, this.body);
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      border: Border.all(color: context.nimbusPalette.line, width: 1.5),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.nimbusPalette.muted),
        ),
      ],
    ),
  );
}
