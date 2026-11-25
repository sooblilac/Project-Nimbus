import 'dart:async';

import 'package:another_telephony/telephony.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../codec/nimbus_codec.dart' as codec;

const _defaultGatewayNumber = String.fromEnvironment('NIMBUS_SMS_GATEWAY');

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
    return true;
  }

  Future<void> stopGateway() => _setBooleanSetting('smsGatewayMode', false);

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

    final request = RegExp(r'^NB1 ASK P ((?:\d{4}|\d{10}))$').firstMatch(body);
    if (request == null || from.trim().isEmpty) return;
    final townCode = request.group(1)!;
    final snapshot = await latestPinSnapshot(townCode);
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final response =
        snapshot == null
            ? codec.encodePins(townCode, const [], time)
            : bodyForSnapshot(townCode, snapshot);
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

  Future<void> _saveReply(codec.Reply reply, String body) async {
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
}

@pragma('vm:entry-point')
Future<void> nimbusSmsBackgroundHandler(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  final service = await SmsService.open();
  await service._handle(message.address ?? '', message.body ?? '');
}
