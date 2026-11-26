import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../lgu/lgu_api.dart';
import '../sms/sms_service.dart';

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.sms,
    required this.darkMode,
    required this.onDarkModeChanged,
  });

  final SmsService sms;
  final bool darkMode;
  final Future<void> Function(bool enabled) onDarkModeChanged;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  final _relayController = TextEditingController();
  final _trustedLguController = TextEditingController();
  final _apiUrlController = TextEditingController();
  final _secureStorage = const FlutterSecureStorage();
  late bool _darkMode = widget.darkMode;
  bool _demoMode = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadGatewayNumber();
  }

  @override
  void dispose() {
    _relayController.dispose();
    _trustedLguController.dispose();
    _apiUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadGatewayNumber() async {
    try {
      final number = await widget.sms.getGatewayNumber();
      final trustedLguNumber = await widget.sms.getTrustedLguNumber();
      final demoMode = await widget.sms.getDemoMode();
      final savedApiUrl = await _secureStorage.read(
        key: LguApiService.apiUrlStorageKey,
      );
      if (!mounted) return;
      setState(() {
        _relayController.text = number;
        _trustedLguController.text = trustedLguNumber;
        _apiUrlController.text =
            savedApiUrl?.trim().isNotEmpty == true
                ? savedApiUrl!.trim()
                : 'https://nimbus-worker.gozocharlyz.workers.dev/api';
        _demoMode = demoMode;
        _loading = false;
      });
    } on DatabaseException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load settings: $error';
        _loading = false;
      });
    }
  }

  String _normalizedPhone(TextEditingController controller) =>
      controller.text.trim().replaceAll(RegExp(r'[\s()-]'), '');

  bool _isValidPhone(String number) =>
      RegExp(r'^(?:\+[1-9]\d{7,14}|0\d{10})$').hasMatch(number);

  Future<void> _saveSmsSettings() async {
    final number = _normalizedPhone(_relayController);
    final trustedLguNumber = _normalizedPhone(_trustedLguController);
    if (number.isNotEmpty && !_isValidPhone(number)) {
      setState(() {
        _error = 'Enter a valid relay number, such as +639171234567.';
      });
      return;
    }
    if (trustedLguNumber.isNotEmpty && !_isValidPhone(trustedLguNumber)) {
      setState(() {
        _error = 'Enter a valid trusted LGU number, such as +639171234567.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.sms.setGatewayNumber(number);
      await widget.sms.setTrustedLguNumber(trustedLguNumber);
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('SMS settings saved.')));
    } on DatabaseException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save the relay number: $error';
      });
    }
  }

  Future<void> _toggleDemoMode(bool enabled) async {
    setState(() {
      _demoMode = enabled;
      _error = null;
    });
    try {
      await widget.sms.setDemoMode(enabled);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(enabled
              ? 'Demo mode enabled. Restart NIMBUS to load Batangas City demo data.'
              : 'Demo mode disabled.'),
        ),
      );
    } on DatabaseException catch (error) {
      if (!mounted) return;
      setState(() {
        _demoMode = !enabled;
        _error = 'Could not save demo mode: $error';
      });
    }
  }

  Future<void> _toggleDarkMode(bool enabled) async {
    setState(() {
      _darkMode = enabled;
      _error = null;
    });
    try {
      await widget.onDarkModeChanged(enabled);
    } on DatabaseException catch (error) {
      if (!mounted) return;
      setState(() {
        _darkMode = !enabled;
        _error = 'Could not save the theme setting: $error';
      });
    }
  }

  Future<void> _saveApiServerUrl() async {
    final url = _apiUrlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _error = 'API server URL cannot be empty.';
      });
      return;
    }
    final apiUrl = _apiUrlController.text.trim();
    final apiUri = Uri.tryParse(apiUrl);
    if (apiUri == null ||
        !apiUri.hasScheme ||
        (apiUri.scheme != 'https' && apiUri.scheme != 'http') ||
        apiUri.host.isEmpty) {
      setState(() {
        _error = 'Enter a valid API URL, such as https://nimbus.example/api.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _secureStorage.write(
        key: LguApiService.apiUrlStorageKey,
        value: url,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('API server URL saved.')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save the API server URL: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Settings',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Demo mode'),
            subtitle: const Text('Batangas City simulation: LGU updates, weather, PAGASA and map pins'),
            secondary: const Icon(Icons.science_outlined),
            value: _demoMode,
            onChanged: _loading || _saving ? null : _toggleDemoMode,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Dark mode'),
            secondary: const Icon(Icons.dark_mode_outlined),
            value: _darkMode,
            onChanged: _toggleDarkMode,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _relayController,
            enabled: !_loading && !_saving,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ()-]')),
            ],
            decoration: const InputDecoration(
              labelText: 'SMS receiver number',
              hintText: '+639171234567',
              helperText:
                  'NIMBUS sends resident requests and LGU pin snapshots here.',
              prefixIcon: Icon(Icons.sms_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _trustedLguController,
            enabled: !_loading && !_saving,
            keyboardType: TextInputType.phone,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ()-]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Trusted LGU sender number',
              hintText: '+639171234567',
              helperText:
                  'On the SIM gateway phone, only this number can post pin snapshots.',
              prefixIcon: Icon(Icons.verified_user_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiUrlController,
            enabled: !_loading && !_saving,
            decoration: const InputDecoration(
              labelText: 'API server URL',
              hintText: 'https://api.example.com',
              helperText:
                  'Enter the URL of the API server for LGU login and resident API access.',
              prefixIcon: Icon(Icons.api_outlined),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _loading || _saving ? null : _saveSmsSettings,
            child:
                _loading || _saving
                    ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Text('Save SMS settings'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _loading || _saving ? null : _saveApiServerUrl,
            child:
                _loading || _saving
                    ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Text('Save API server URL'),
          ),
        ],
      ),
    ),
  );
}
