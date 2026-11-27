import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import 'data/philippine_location.dart';
import 'sms/sms_service.dart';
import 'ui/home_screen.dart';
import 'ui/gateway_screen.dart';
import 'ui/lgu_dashboard_screen.dart';
import 'ui/settings_panel.dart';
import 'ui/theme.dart';
import 'ui/welcome_screen_v2.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final locations = await loadPhilippineLocations();
  final outline = await loadPhilippineOutline();
  final sms = await SmsService.open();
  final darkMode = await sms.getDarkMode();
  runApp(
    NimbusApp(
      sms: sms,
      locations: locations,
      outline: outline,
      initialDarkMode: darkMode,
    ),
  );
}

class NimbusApp extends StatefulWidget {
  const NimbusApp({
    super.key,
    required this.sms,
    required this.locations,
    required this.outline,
    required this.initialDarkMode,
  });

  final SmsService sms;
  final List<PhilippineLocation> locations;
  final PhilippineOutline outline;
  final bool initialDarkMode;

  @override
  State<NimbusApp> createState() => _NimbusAppState();
}

class _NimbusAppState extends State<NimbusApp> {
  _AppPage _page = _AppPage.landing;
  late bool _darkMode = widget.initialDarkMode;
  bool _opening = false;
  String? _openError;

  final _navigatorKey = GlobalKey<NavigatorState>();

  Future<void> _setDarkMode(bool enabled) async {
    await widget.sms.setDarkMode(enabled);
    if (mounted) setState(() => _darkMode = enabled);
  }

  Future<void> _openSettings() {
    final navigatorContext = _navigatorKey.currentContext;
    if (navigatorContext == null) return Future<void>.value();
    return showModalBottomSheet<void>(
      context: navigatorContext,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (context) => SettingsPanel(
            sms: widget.sms,
            darkMode: _darkMode,
            onDarkModeChanged: _setDarkMode,
          ),
    );
  }

  Future<void> _open(bool startAsLgu) async {
    setState(() {
      _opening = true;
      _openError = null;
    });
    try {
      if (!await widget.sms.start()) {
        if (!mounted) return;
        setState(() {
          _opening = false;
          _openError =
              'SMS permission is required to request updates and sync LGU map pins.';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _page = startAsLgu ? _AppPage.lgu : _AppPage.resident;
        _opening = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _openError = 'Could not start SMS support: $error';
      });
    }
  }

  Future<void> _openGateway() async {
    setState(() {
      _opening = true;
      _openError = null;
    });
    try {
      if (!await widget.sms.startGateway()) {
        if (!mounted) return;
        setState(() {
          _opening = false;
          _openError = 'SMS permission is required to run the gateway.';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _page = _AppPage.gateway;
        _opening = false;
      });
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _openError = error.message.toString();
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _openError =
            'Could not start the SMS gateway: ${error.message ?? error.code}';
      });
    } on DatabaseException catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _openError = 'Could not start the SMS gateway: $error';
      });
    }
  }

  Future<void> _stopGateway() async {
    await widget.sms.stopGateway();
    if (mounted) setState(() => _page = _AppPage.landing);
  }

  void _backToLanding() {
    setState(() {
      _page = _AppPage.landing;
      _opening = false;
      _openError = null;
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    title: 'NIMBUS',
    debugShowCheckedModeBanner: false,
    theme: nimbusTheme(dark: _darkMode),
    home: switch (_page) {
      _AppPage.landing => WelcomeScreenV2(
        opening: _opening,
        error: _openError,
        onOpen: _open,
        onOpenGateway: _openGateway,
        onSettings: _openSettings,
      ),
      _AppPage.resident => HomeScreen(
        sms: widget.sms,
        locations: widget.locations,
        outline: widget.outline,
        onBack: _backToLanding,
        onSettings: _openSettings,
      ),
      _AppPage.lgu => LguDashboardScreen(
        sms: widget.sms,
        locations: widget.locations,
        outline: widget.outline,
        onBack: _backToLanding,
        onSettings: _openSettings,
      ),
      _AppPage.gateway => GatewayScreen(sms: widget.sms, onStop: _stopGateway),
    },
  );
}

enum _AppPage { landing, resident, lgu, gateway }
