import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:sqflite/sqflite.dart';

import '../data/philippine_location.dart';
import '../data/town_pack.dart';
import '../lgu/lgu_api.dart';
import '../sms/sms_service.dart';
import 'lgu_console.dart';
import 'location_picker.dart';
import 'storm_map.dart';
import 'theme.dart';

class LguDashboardScreen extends StatefulWidget {
  const LguDashboardScreen({
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
  State<LguDashboardScreen> createState() => _LguDashboardScreenState();
}

class _LguDashboardScreenState extends State<LguDashboardScreen> {
  final _api = LguApiService();
  static const _savedLguLoginKey = 'saved_lgu_login';
  final _secureStorage = const FlutterSecureStorage();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  late PhilippineLocation _location;
  String? _accessToken;
  String? _username;
  List<String> _townCodes = [];
  LguUpdate? _publishedUpdate;
  List<MapPinUpdate> _mapPins = [];
  bool _pinPlacementMode = false;
  (String category, String label)? _placementTarget;
  MapPinLocationSelection? _pinLocationSelection;
  int _pinSelectionId = 0;
  bool _authenticating = false;
  bool _restoringLogin = false;
  bool _apiLoading = false;
  String? _authError;
  String? _apiError;
  int _requestId = 0;
  int _consoleRevision = 0;
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    _location = widget.locations.first;
    _authenticating = true;
    _restoringLogin = true;
    unawaited(_restoreLogin());
  }

  Future<void> _restoreLogin() async {
    try {
      final saved = await _secureStorage.read(key: _savedLguLoginKey);
      if (saved == null) return;
      final decoded = jsonDecode(saved);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Saved LGU sign-in data is invalid.');
      }
      final username = decoded['username'];
      final password = decoded['password'];
      if (username is! String ||
          username.trim().isEmpty ||
          password is! String ||
          password.isEmpty) {
        throw const FormatException('Saved LGU sign-in data is incomplete.');
      }
      _usernameController.text = username;
      _passwordController.text = password;
      final session = await _api.login(username, password);
      await _acceptSession(session);
    } on LguApiException catch (error) {
      if (mounted) {
        setState(
          () => _authError = 'Could not restore LGU sign-in: ${error.message}',
        );
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(
          () => _authError = 'Could not restore LGU sign-in: ${error.message}',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () =>
              _authError =
                  'Could not read the saved LGU sign-in: ${error.message ?? error.code}',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _authenticating = false;
          _restoringLogin = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  List<PhilippineLocation> get _availableLocations {
    if (_townCodes.contains('*')) return widget.locations;
    return widget.locations
        .where(
          (location) =>
              _townCodes.contains(location.code) ||
              _townCodes.contains(location.smsCode),
        )
        .toList();
  }

  Future<void> _login() async {
    if (_authenticating) return;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _authError = 'Enter your LGU username and password.');
      return;
    }

    setState(() {
      _authenticating = true;
      _authError = null;
    });
    try {
      final session = await _api.login(username, password);
      await _acceptSession(session);
      try {
        await _secureStorage.write(
          key: _savedLguLoginKey,
          value: jsonEncode({'username': username, 'password': password}),
        );
      } on PlatformException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Signed in, but this device could not securely remember the login: '
                '${error.message ?? error.code}',
              ),
            ),
          );
        }
      }
    } on LguApiException catch (error) {
      if (mounted) setState(() => _authError = error.message);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() => _authError = 'The login response was invalid: $error');
      }
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  Future<void> _acceptSession(LguSession session) async {
    final allowedLocations =
        session.townCodes.contains('*')
            ? widget.locations
            : widget.locations
                .where(
                  (location) =>
                      session.townCodes.contains(location.code) ||
                      session.townCodes.contains(location.smsCode),
                )
                .toList();
    if (allowedLocations.isEmpty) {
      await _api.logout(session.accessToken);
      throw const LguApiException(
        'This account has no town assigned in the location catalog.',
      );
    }
    if (!mounted) return;
    setState(() {
      _accessToken = session.accessToken;
      _username = session.username;
      _townCodes = session.townCodes;
      _location = allowedLocations.first;
      _apiLoading = true;
      _apiError = null;
      _authError = null;
    });
    _loadUpdate(_location.code);
  }

  Future<void> _logout() async {
    final token = _accessToken;
    setState(() {
      _accessToken = null;
      _username = null;
      _townCodes = [];
      _publishedUpdate = null;
      _apiLoading = false;
      _apiError = null;
      _authError = null;
    });
    final warnings = <String>[];
    try {
      await _secureStorage.delete(key: _savedLguLoginKey);
    } on PlatformException catch (error) {
      warnings.add(
        'Saved login could not be removed from this device: '
        '${error.message ?? error.code}.',
      );
    }
    if (token != null) {
      try {
        await _api.logout(token);
      } on LguApiException catch (error) {
        warnings.add(
          'The server session could not be revoked: ${error.message}',
        );
      }
    }
    if (warnings.isNotEmpty && mounted) {
      setState(() => _authError = 'Signed out. ${warnings.join(' ')}');
    }
  }

  Future<void> _loadUpdate(String townCode) async {
    final requestId = ++_requestId;
    try {
      final update = await _api.fetchTown(townCode);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _publishedUpdate = update;
        _mapPins = update?.mapPins ?? [];
        _apiLoading = false;
        _apiError = null;
      });
    } on LguApiException catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _apiLoading = false;
        _apiError = error.message;
      });
    } on FormatException catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _apiLoading = false;
        _apiError = 'The API returned invalid data: ${error.message}';
      });
    }
  }

  void _onLocationSelected(PhilippineLocation location) {
    setState(() {
      _location = location;
      _publishedUpdate = null;
      _mapPins = [];
      _pinPlacementMode = false;
      _placementTarget = null;
      _pinLocationSelection = null;
      _apiLoading = true;
      _apiError = null;
    });
    _loadUpdate(location.code);
  }

  void _onPublished(LguUpdate update) {
    setState(() {
      _publishedUpdate = update;
      _mapPins = update.mapPins;
      _apiLoading = false;
      _apiError = null;
    });
  }

  void _retry() {
    setState(() {
      _apiLoading = true;
      _apiError = null;
    });
    _loadUpdate(_location.code);
  }

  void _requestPinLocation((String category, String label) target) {
    setState(() {
      _placementTarget = target;
      _pinPlacementMode = true;
    });
  }

  void _cancelPinPlacement((String category, String label) target) {
    if (_placementTarget != target) return;
    setState(() {
      _placementTarget = null;
      _pinPlacementMode = false;
    });
  }

  void _handleMapTap(double latitude, double longitude) {
    final target = _placementTarget;
    if (target == null) return;
    setState(() {
      _pinLocationSelection = MapPinLocationSelection(
        requestId: ++_pinSelectionId,
        category: target.$1,
        label: target.$2,
        latitude: latitude,
        longitude: longitude,
      );
      _placementTarget = null;
      _pinPlacementMode = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Map location selected. Publish to share the update.'),
      ),
    );
  }

  Future<void> _resetTownUpdates() async {
    final token = _accessToken;
    if (token == null || _resetting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text('Reset ${_location.name} updates?'),
            content: const Text(
              'This deletes the published LGU report and resident SMS replies '
              'saved on this device for this town. It cannot erase copies on '
              'other residents’ phones.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Reset'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _resetting = true);
    try {
      await _api.deleteTown(_location.code, accessToken: token);
      try {
        await widget.sms.clearTown(_location.smsCode);
        if (_location.code != _location.smsCode) {
          await widget.sms.clearTown(_location.code);
        }
      } on DatabaseException catch (error) {
        if (mounted) {
          setState(() {
            _publishedUpdate = null;
            _mapPins = [];
            _apiLoading = false;
            _apiError = null;
            _consoleRevision++;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'The LGU report was deleted, but resident history on this '
                'device could not be cleared: $error',
              ),
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _publishedUpdate = null;
        _mapPins = [];
        _apiLoading = false;
        _apiError = null;
        _consoleRevision++;
        _requestId++;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_location.name} updates were reset.')),
      );
    } on LguApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not reset town updates: ${error.message}'),
          ),
        );
      }
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reset town updates: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  Widget _buildLogin(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: [
          Text(
            'LGU sign in',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'Sign in to publish verified updates for your assigned town.',
            style: TextStyle(color: context.nimbusPalette.muted),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _usernameController,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Username',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
            decoration: const InputDecoration(
              labelText: 'Password',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          if (_authError != null) ...[
            const SizedBox(height: 12),
            _LoginMessage(_authError!),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _authenticating ? null : _login,
            icon:
                _authenticating
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.login),
            label: Text(
              _restoringLogin
                  ? 'Restoring saved sign-in…'
                  : _authenticating
                  ? 'Signing in…'
                  : 'Sign in',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This device remembers your login securely until you sign out.',
            style: TextStyle(color: context.nimbusPalette.muted),
          ),
        ],
      ),
    ),
  );

  Widget _buildDashboard(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
    children: [
      Text(
        'Town or city',
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 6),
      Text(
        'Signed in as ${_username ?? 'LGU staff'}. Select a location you are authorized to report for.',
        style: TextStyle(color: context.nimbusPalette.muted),
      ),
      const SizedBox(height: 12),
      LocationPicker(
        location: _location,
        locations: _availableLocations,
        onSelected: _onLocationSelected,
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 320,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              Positioned.fill(
                child: StormMap(
                  location: _location,
                  outline: widget.outline,
                  mapPins: _mapPins,
                  pinPlacementMode: _pinPlacementMode,
                  onMapTap: _handleMapTap,
                  floodReported:
                      _publishedUpdate?.floodAreas.any(
                        (area) => area.status == 'F',
                      ) ??
                      false,
                ),
              ),
              if (_pinPlacementMode && _placementTarget != null)
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                      child: Row(
                        children: [
                          const Icon(Icons.add_location_alt_outlined),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Pan or zoom, then tap to place '
                              '${_placementTarget!.$2}.',
                            ),
                          ),
                          IconButton(
                            tooltip: 'Cancel pin placement',
                            onPressed:
                                () => _cancelPinPlacement(_placementTarget!),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 22),
      LguConsole(
        key: ValueKey('${_location.code}-$_consoleRevision'),
        town: townForLocation(_location),
        api: _api,
        pinSnapshotSender: widget.sms,
        accessToken: _accessToken,
        existingUpdate: _publishedUpdate,
        mapPins: _mapPins,
        onMapPinsChanged: (pins) => setState(() => _mapPins = pins),
        onRequestPinLocation: _requestPinLocation,
        onCancelPinPlacement: _cancelPinPlacement,
        pinLocationSelection: _pinLocationSelection,
        apiLoading: _apiLoading,
        apiError: _apiError,
        onRetry: _retry,
        onPublished: _onPublished,
        resetting: _resetting,
        onReset: _resetTownUpdates,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: 'Back to NIMBUS',
        onPressed: widget.onBack,
        icon: const Icon(Icons.arrow_back),
      ),
      title: Text(
        _accessToken == null ? 'NIMBUS · LGU login' : 'NIMBUS · LGU dashboard',
      ),
      actions: [
        IconButton(
          tooltip: 'Settings',
          onPressed: widget.onSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
        if (_accessToken != null)
          IconButton(
            tooltip: 'Sign out',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
      ],
    ),
    body: SafeArea(
      child:
          _accessToken == null
              ? _buildLogin(context)
              : _buildDashboard(context),
    ),
  );
}

class _LoginMessage extends StatelessWidget {
  const _LoginMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.nimbusPalette.surfaceAlt,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(message, style: const TextStyle(color: NimbusColors.danger)),
  );
}
