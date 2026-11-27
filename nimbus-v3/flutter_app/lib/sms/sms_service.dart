import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:another_telephony/telephony.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../codec/nimbus_codec.dart' as codec;

const _defaultGatewayNumber = String.fromEnvironment(
  'NIMBUS_SMS_GATEWAY',
  defaultValue: '09263180296',
);
const _defaultApiUrl =
    'https://nimbus-worker.gozocharlyz.workers.dev/api';
const _cloudflareSyncInterval = Duration(seconds: 30);

class SavedUpdate {
  const SavedUpdate(this.type, this.townCode, this.sms, this.received);
  final String type;
  final String townCode;
  final String sms;
  final DateTime received;
}

abstract interface class PinSnapshotSender {
  Future<void> sendPinSnapshot(String townCode, List<codec.MapPin> pins);
}

/// Handles resident pin requests and the SIM-phone pin gateway.
class SmsService implements PinSnapshotSender {
  SmsService._(this._db);

  static Future<SmsService> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'nimbus.db'),
      version: 2,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE saved_updates (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, town TEXT, sms TEXT, received INTEGER)',
        );
        await db.execute(
          'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute(
            'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        }
      },
    );
    return SmsService._(db);
  }

  final Database _db;
  final _telephony = Telephony.instance;
  Timer? _inboxSyncTimer;
  Timer? _cloudflareSyncTimer;

  final _replies = StreamController<SavedUpdate>.broadcast();

  Stream<SavedUpdate> get replies => _replies.stream;

  Future<bool> start() => _start(gatewayMode: false);

  Future<bool> startGateway() async {
    if ((await getTrustedLguNumber()).trim().isEmpty) {
      throw StateError(
        'Set the trusted LGU sender number before starting the SMS gateway.',
      );
    }
    return _start(gatewayMode: true);
  }

  Future<bool> _start({required bool gatewayMode}) async {
    final granted = await _telephony.requestSmsPermissions ?? false;
    if (!granted) return false;
    await _setBooleanSetting('smsGatewayMode', gatewayMode);
    _telephony.listenIncomingSms(
      onNewMessage:
          (message) => _handle(message.address ?? '', message.body ?? ''),
      onBackgroundMessage: nimbusSmsBackgroundHandler,
    );
    if (!gatewayMode) {
      _inboxSyncTimer?.cancel();
      await syncInboxReplies();
      _inboxSyncTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(syncInboxReplies()),
      );
    } else {
      _inboxSyncTimer?.cancel();
      _inboxSyncTimer = null;
      await syncCloudflareUpdates();
      _cloudflareSyncTimer?.cancel();
      _cloudflareSyncTimer = Timer.periodic(
        _cloudflareSyncInterval,
        (_) => unawaited(syncCloudflareUpdates()),
      );
    }
    return true;
  }

  Future<void> stopGateway() async {
    _cloudflareSyncTimer?.cancel();
    _cloudflareSyncTimer = null;
    _inboxSyncTimer?.cancel();
    _inboxSyncTimer = null;
    await _setBooleanSetting('smsGatewayMode', false);
  }

  Future<bool> getGatewayMode() => _getBooleanSetting('smsGatewayMode');

  Future<String> getTrustedLguNumber() async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['trustedLguNumber'],
      limit: 1,
    );
    return rows.isEmpty ? '' : rows.single['value'] as String;
  }

  Future<void> setTrustedLguNumber(String number) async {
    await _db.insert('app_settings', {
      'key': 'trustedLguNumber',
      'value': number,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String> getGatewayNumber() async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['smsGateway'],
      limit: 1,
    );
    if (rows.isEmpty) return _defaultGatewayNumber;
    return rows.single['value'] as String;
  }

  Future<void> setGatewayNumber(String number) async {
    await _db.insert('app_settings', {
      'key': 'smsGateway',
      'value': number,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> cacheJson(String key, String json) async {
    await _db.insert('app_settings', {
      'key': 'cache:$key',
      'value': json,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> cachedJson(String key) async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['cache:$key'],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<bool> getDarkMode() async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['darkMode'],
      limit: 1,
    );
    return rows.isNotEmpty && rows.single['value'] == 'true';
  }

  Future<void> setDarkMode(bool enabled) async {
    await _setBooleanSetting('darkMode', enabled);
  }

  Future<bool> getDemoMode() => _getBooleanSetting('demoMode');

  Future<void> setDemoMode(bool enabled) async {
    await _setBooleanSetting('demoMode', enabled);
  }

  Future<bool> _getBooleanSetting(String key) async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isNotEmpty && rows.single['value'] == 'true';
  }

  Future<void> _setBooleanSetting(String key, bool enabled) async {
    await _db.insert('app_settings', {
      'key': key,
      'value': enabled ? 'true' : 'false',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// One tap sends one text: NB1 ASK <type> <town>.
  Future<void> ask(String type, String townCode) async {
    final gatewayNumber = (await getGatewayNumber()).trim();
    if (gatewayNumber.isEmpty) {
      throw StateError(
        'Configure the SMS relay number before requesting an update.',
      );
    }
    await _telephony.sendSms(
      to: gatewayNumber,
      message: 'NB1 ASK $type $townCode',
    );
  }

  @override
  Future<void> sendPinSnapshot(String townCode, List<codec.MapPin> pins) async {
    final gatewayNumber = (await getGatewayNumber()).trim();
    if (gatewayNumber.isEmpty) {
      throw StateError(
        'Configure the SMS receiver number before syncing map pins.',
      );
    }
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final message = codec.encodePins(townCode, pins, time);
    await _telephony.sendSms(
      to: gatewayNumber,
      message: message,
      isMultipart: message.length > codec.maxSms,
    );
  }

  Future<void> syncInboxReplies() async {
    final gatewayNumber = (await getGatewayNumber()).trim();
    if (gatewayNumber.isEmpty) return;
    final messages = await _telephony.getInboxSms();
    for (final message in messages.take(30)) {
      final from = message.address ?? '';
      if (!_samePhoneNumber(from, gatewayNumber)) continue;
      final reply = codec.decode(message.body ?? '');
      if (reply == null || !reply.valid) continue;
      await _saveReply(reply, message.body ?? '', replaceDuplicate: true);
    }
  }

  Future<SavedUpdate?> latestTypeSnapshot(String type, String townCode) async {
    final rows = await _db.query(
      'saved_updates',
      where: 'town = ? AND type = ?',
      whereArgs: [townCode, type],
      orderBy: 'received DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.single;
    return SavedUpdate(
      r['type'] as String,
      r['town'] as String,
      r['sms'] as String,
      DateTime.fromMillisecondsSinceEpoch(r['received'] as int),
    );
  }

  Future<codec.Reply?> latestPinSnapshot(String townCode) async {
    final rows = await _db.query(
      'saved_updates',
      columns: ['sms'],
      where: 'town = ? AND type = ?',
      whereArgs: [townCode, 'P'],
      orderBy: 'received DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final reply = codec.decode(rows.single['sms'] as String);
    if (reply == null || !reply.valid || reply.type != 'P') {
      throw const FormatException('The saved map pin snapshot is invalid.');
    }
    return reply;
  }

  Future<void> _handle(String from, String body) async {
    if (await getGatewayMode()) {
      await _handleGateway(from, body);
      return;
    }
    await _handleResidentReply(from, body);
  }

  Future<void> _handleResidentReply(String from, String body) async {
    final gatewayNumber = await getGatewayNumber();
    if (gatewayNumber.isEmpty || !_samePhoneNumber(from, gatewayNumber)) return;
    final reply = codec.decode(body);
    if (reply == null || !reply.valid) return;
    await _saveReply(reply, body);
  }

  Future<void> _handleGateway(String from, String body) async {
    final reply = codec.decode(body);
    if (reply != null &&
        reply.type == 'P' &&
        reply.valid &&
        _samePhoneNumber(from, await getTrustedLguNumber())) {
      await _saveReply(reply, body);
      return;
    }

    final request = RegExp(r'^NB1 ASK ([QFERCPA]) ((?:\d{4}|\d{10}))$').firstMatch(body);
    if (request == null || from.trim().isEmpty) return;
    final type = request.group(1)!;
    final townCode = request.group(2)!;
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';

    String response;
    if (type == 'P') {
      final snapshot = await latestPinSnapshot(townCode);
      response = snapshot == null
          ? codec.encodePins(townCode, const [], time)
          : bodyForSnapshot(townCode, snapshot);
    } else if (type == 'Q') {
      final snapshot = await latestTypeSnapshot('Q', '0000');
      response = snapshot?.sms ??
          codec.encode('Q', '0000', ['WNone', 'R0', 'G0', 'E0', 'C0'], time,
              'No storm updates yet');
    } else {
      final snapshot = await latestTypeSnapshot(type, townCode);
      response = snapshot?.sms ??
          codec.encode(type, townCode, const [], time,
              'No current $type update');
    }

    await _telephony.sendSms(
      to: from,
      message: response,
      isMultipart: response.length > codec.maxSms,
    );
  }

  String bodyForSnapshot(String townCode, codec.Reply snapshot) {
    final time = snapshot.time;
    return codec.encodePins(townCode, snapshot.pins, time);
  }

  Future<void> _saveReply(codec.Reply reply, String body,
      {bool replaceDuplicate = false}) async {
    final existing = await _db.query(
      'saved_updates',
      where: 'type = ? AND town = ? AND sms = ?',
      whereArgs: [reply.type, reply.townCode, body],
      limit: 1,
    );
    if (existing.isNotEmpty && replaceDuplicate) return;

    final update = SavedUpdate(
      reply.type,
      reply.townCode,
      body,
      DateTime.now(),
    );
    await _db.insert('saved_updates', {
      'type': update.type,
      'town': update.townCode,
      'sms': update.sms,
      'received': update.received.millisecondsSinceEpoch,
    });
    _replies.add(update);
  }

  bool _samePhoneNumber(String first, String second) {
    String last10(String number) {
      final digits = number.replaceAll(RegExp(r'\D'), '');
      return digits.length <= 10
          ? digits
          : digits.substring(digits.length - 10);
    }

    final firstDigits = last10(first);
    return firstDigits.isNotEmpty && firstDigits == last10(second);
  }

  Future<List<SavedUpdate>> saved() async {
    final rows = await _db.query(
      'saved_updates',
      orderBy: 'received DESC',
      limit: 20,
    );
    return [
      for (final r in rows)
        SavedUpdate(
          r['type'] as String,
          r['town'] as String,
          r['sms'] as String,
          DateTime.fromMillisecondsSinceEpoch(r['received'] as int),
        ),
    ];
  }

  Future<int> clearTown(String townCode) =>
      _db.delete('saved_updates', where: 'town = ?', whereArgs: [townCode]);

  /// Loads a prebuilt/mock NB1 reply into the same saved-update stream used
  /// by real SMS, so hackathon demos and offline previews need no gateway.
  Future<void> injectDemoReply(String sms) async {
    final reply = codec.decode(sms);
    if (reply == null || !reply.valid) {
      throw const FormatException('The demo NB1 reply is invalid.');
    }
    await _saveReply(reply, sms, replaceDuplicate: true);
  }

  Future<void> syncCloudflareUpdates() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      Future<Map<String, dynamic>> getJson(String path) async {
        final request = await client.getUrl(Uri.parse('$_defaultApiUrl/$path'));
        final response = await request.close().timeout(const Duration(seconds: 8));
        final text = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 8));
        final decoded = jsonDecode(text);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError('Cloudflare API request failed (${response.statusCode}).');
        }
        if (decoded is! Map<String, dynamic>) throw const FormatException('Invalid Cloudflare API response.');
        return decoded;
      }

      final townsResponse = await getJson('towns');
      final towns = townsResponse['towns'];
      if (towns is List) {
        for (final town in towns) {
          if (town is! Map<String, dynamic>) continue;
          final townCode = town['townCode'];
          final update = town['update'];
          if (townCode is! String || update is! Map<String, dynamic>) continue;
          await _saveLguSmsUpdates(townCode, update);
        }
      }

      final pagasa = await getJson('pagasa');
      await _savePagasaSmsUpdate(pagasa);
    } catch (_) {
      // Gateway stays usable offline and retries on the next polling interval.
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _saveLguSmsUpdates(String townCode, Map<String, dynamic> update) async {
    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';

    final notice = _notice(update);
    if (notice.isNotEmpty) {
      await injectEncodedReply(
        codec.encode('A', townCode, const [], time, notice),
        'A',
        townCode,
      );
    }

    final classes = update['classes'];
    if (classes is int) {
      await injectEncodedReply(codec.encode('C', townCode, ['C$classes'], time, _notice(update)), 'C', townCode);
    }

    final floodAreas = update['floodAreas'];
    if (floodAreas is List) {
      final fields = <String>[];
      for (var i = 0; i < floodAreas.length; i++) {
        final area = floodAreas[i];
        if (area is! Map) continue;
        final name = codec.cleanNotice(area['name']?.toString() ?? '')
            .replaceAll(':', ' ').replaceAll(RegExp(r'\s+'), '_');
        final level = area['level'];
        final status = area['status'];
        if (!{'H', 'M', 'L'}.contains(level) || !{'F', 'W', 'C'}.contains(status)) continue;
        fields.add('A${i + 1}$level$status${name.isEmpty ? '' : ':$name'}');
      }
      await injectEncodedReply(codec.encode('F', townCode, fields, time, _notice(update)), 'F', townCode);
    }

    final evacAreas = update['evacuationCenters'];
    if (evacAreas is List) {
      final fields = <String>[];
      for (var i = 0; i < evacAreas.length; i++) {
        final center = evacAreas[i];
        if (center is! Map) continue;
        final status = center['status'];
        final percent = center['percentFull'];
        if (!{'O', 'F', 'X'}.contains(status) || percent is! int || percent < 0 || percent > 100) continue;
        fields.add('S${i + 1}$status$percent');
      }
      await injectEncodedReply(codec.encode('E', townCode, fields, time, _notice(update)), 'E', townCode);
    }

    final roads = update['roadStatuses'];
    if (roads is List) {
      final fields = <String>[];
      for (var i = 0; i < roads.length; i++) {
        final road = roads[i];
        if (road is! Map) continue;
        final name = codec.cleanNotice((road['name']?.toString() ?? '')
            .replaceAll(':', ' ')
            .replaceAll(RegExp(r'\s+'), '_'));
        final status = road['status'];
        if (!{'O', 'L', 'X'}.contains(status)) continue;
        fields.add('R${i + 1}$status${name.isEmpty ? '' : ':$name'}');
      }
      await injectEncodedReply(codec.encode('R', townCode, fields, time, _notice(update)), 'R', townCode);
    }

    final pins = update['mapPins'];
    if (pins is List) {
      final parsed = <codec.MapPin>[];
      for (final pin in pins) {
        if (pin is! Map) continue;
        final latitude = pin['latitude'];
        final longitude = pin['longitude'];
        final intensity = pin['intensity'];
        if (pin['category'] is! String || pin['label'] is! String ||
            latitude is! num || longitude is! num || intensity is! int) continue;
        parsed.add(codec.MapPin(
          category: pin['category'] as String,
          label: pin['label'] as String,
          latitude: latitude.toDouble(),
          longitude: longitude.toDouble(),
          status: pin['status'] as String,
          intensity: intensity,
        ));
      }
      await injectEncodedReply(codec.encodePins(townCode, parsed, time), 'P', townCode);
    }
  }

  String _notice(Map<String, dynamic> update) {
    return codec.cleanNotice(update['notice']?.toString() ?? '');
  }

  Future<void> _savePagasaSmsUpdate(Map<String, dynamic> pagasa) async {
    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final active = pagasa['active'] == true;
    final warning = active
        ? codec.cleanNotice(pagasa['message']?.toString() ?? 'PAGASA storm update')
            .replaceAll(RegExp(r'\s+'), '_')
        : 'None';
    final rain = pagasa['rain'] is int ? pagasa['rain'] as int : 0;
    final gusts = pagasa['gusts'] is int ? pagasa['gusts'] as int : 0;
    final fields = ['W$warning', 'R$rain', 'G$gusts', 'E0', 'C0'];
    final notice = active
        ? codec.cleanNotice(pagasa['message']?.toString() ?? 'PAGASA storm update')
        : 'No storm updates yet';
    await injectEncodedReply(codec.encode('Q', '0000', fields, time, notice), 'Q', '0000');
  }

  Future<void> injectEncodedReply(String sms, String type, String townCode) async {
    final reply = codec.decode(sms);
    if (reply == null || !reply.valid) {
      throw const FormatException('Could not encode the gateway reply.');
    }
    await _saveReply(reply, sms, replaceDuplicate: true);
  }
}

@pragma('vm:entry-point')
Future<void> nimbusSmsBackgroundHandler(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  final service = await SmsService.open();
  await service._handle(message.address ?? '', message.body ?? '');
}
