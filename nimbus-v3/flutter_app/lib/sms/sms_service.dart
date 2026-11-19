import 'dart:async';

import 'package:another_telephony/telephony.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../codec/nimbus_codec.dart' as codec;

/// The Nimbus gateway number. Replace with your LTE modem's SIM before testing.
const gatewayNumber = '+639000000000';

class SavedUpdate {
  const SavedUpdate(this.type, this.townCode, this.sms, this.received);
  final String type;
  final String townCode;
  final String sms;
  final DateTime received;
}

/// Sends NB1 requests, listens for replies from the gateway and keeps every reply in SQLite,
/// stored exactly as the SMS arrived so it can be reopened offline.
class SmsService {
  SmsService._(this._db);

  static Future<SmsService> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'nimbus.db'),
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE saved_updates (id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, town TEXT, sms TEXT, received INTEGER)',
      ),
    );
    return SmsService._(db);
  }

  final Database _db;
  final _telephony = Telephony.instance;
  final _replies = StreamController<SavedUpdate>.broadcast();

  Stream<SavedUpdate> get replies => _replies.stream;

  Future<bool> start() async {
    final granted = await _telephony.requestPhoneAndSmsPermissions ?? false;
    if (!granted) return false;
    _telephony.listenIncomingSms(
      onNewMessage: (message) => _handle(message.address ?? '', message.body ?? ''),
      listenInBackground: false,
    );
    return true;
  }

  /// One tap sends one text: NB1 ASK <type> <town>.
  Future<void> ask(String type, String townCode) =>
      _telephony.sendSms(to: gatewayNumber, message: 'NB1 ASK $type $townCode');

  Future<void> _handle(String from, String body) async {
    // Carriers format the sender differently (+63…, 63…, 0…), so compare the last 10 digits.
    String last10(String n) {
      final digits = n.replaceAll(RegExp(r'\D'), '');
      return digits.length <= 10 ? digits : digits.substring(digits.length - 10);
    }
    if (last10(from) != last10(gatewayNumber)) return;
    final reply = codec.decode(body);
    if (reply == null) return;
    final update = SavedUpdate(reply.type, reply.townCode, body, DateTime.now());
    await _db.insert('saved_updates', {
      'type': update.type,
      'town': update.townCode,
      'sms': update.sms,
      'received': update.received.millisecondsSinceEpoch,
    });
    _replies.add(update);
  }

  Future<List<SavedUpdate>> saved() async {
    final rows = await _db.query('saved_updates', orderBy: 'received DESC', limit: 20);
    return [
      for (final r in rows)
        SavedUpdate(r['type'] as String, r['town'] as String, r['sms'] as String,
            DateTime.fromMillisecondsSinceEpoch(r['received'] as int)),
    ];
  }
}
