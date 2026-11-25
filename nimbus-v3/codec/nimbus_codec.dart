// Nimbus SMS format NB1 for the Flutter app. Mirrors nimbus-codec.js line for line.
//
//   NB1 <type> <town> <field> ... T<hhmm> [/<notice>] K<signature>
//
// The K signature is a demo checksum. A real gateway signs with HMAC-SHA256.
// Check it against test_vectors.json before relying on it.

const String nbVersion = 'NB1';
const int maxSms = 160;

/// h = h * 31 + UTF-16 code unit, kept to 32 bits; returns the low 16 bits as 4 hex digits.
String signature(String text) {
  var h = 0;
  for (final unit in text.codeUnits) {
    h = (h * 31 + unit) & 0xFFFFFFFF;
  }
  return (h & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');
}

/// Keeps a notice in the plain SMS character set so one reply stays one SMS.
String cleanNotice(String text) => text
    .replaceAll(RegExp('[‘’]'), "'")
    .replaceAll(RegExp('[“”]'), '"')
    .replaceAll(RegExp('[–—]'), '-')
    .replaceAll(RegExp(r'[^\x20-\x7E]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String encode(String type, String townCode, List<String> fields, String time, [String notice = '']) {
  var body = [nbVersion, type, townCode, ...fields, 'T$time'].join(' ');
  if (notice.isNotEmpty) body += ' /$notice';
  return '$body K${signature(body)}';
}

class Storm {
  const Storm(this.warning, this.rain, this.gusts, this.evacSite, this.evacStatus, this.classes);
  final String warning;
  final int rain;
  final int gusts;
  final int evacSite;
  final String evacStatus;
  final int classes;
}

class Item {
  const Item(this.index, {this.level, this.now, this.status, this.percentFull, this.customName});
  final int index;
  final String? level;
  final String? now;
  final String? status;
  final int? percentFull;
  final String? customName;
}

class Reply {
  Reply(this.version, this.type, this.townCode, this.time, this.notice, this.valid);
  final String version;
  final String type;
  final String townCode;
  final String time;
  final String notice;
  final bool valid;
  Storm? storm;
  final List<Item> items = [];
}

final _flood = RegExp(r'^A(\d+)([HML])([FWC])(?::(\S+))?$');
final _evac = RegExp(r'^S(\d+)([OFX])(\d+)$');
final _road = RegExp(r'^R(\d+)([OLX])(?::(\S+))?$');

Item? _parseField(String type, String part) {
  RegExpMatch? m;
  if (type == 'F' && (m = _flood.firstMatch(part)) != null) {
    return Item(int.parse(m!.group(1)!), level: m.group(2), now: m.group(3), customName: m.group(4)?.replaceAll('_', ' '));
  }
  if (type == 'E' && (m = _evac.firstMatch(part)) != null) {
    return Item(int.parse(m!.group(1)!), status: m.group(2), percentFull: int.parse(m.group(3)!));
  }
  if (type == 'R' && (m = _road.firstMatch(part)) != null) {
    return Item(int.parse(m!.group(1)!), status: m.group(2), customName: m.group(3)?.replaceAll('_', ' '));
  }
  return null;
}

/// Returns null for anything that isn't an NB1 reply, so a stray text never crashes the app.
Reply? decode(String sms) {
  final k = sms.lastIndexOf(' K');
  if (k < 0 || !sms.startsWith('$nbVersion ')) return null;
  final body = sms.substring(0, k);
  final n = body.indexOf(' /');
  final parts = (n >= 0 ? body.substring(0, n) : body).split(' ');
  if (parts.length < 4) return null;
  final type = parts[1];
  final items = parts.sublist(3, parts.length - 1);
  final timePart = parts.last;
  if (!RegExp(r'^T\d{4}$').hasMatch(timePart)) return null;
  final reply = Reply(parts[0], type, parts[2], timePart.substring(1), n >= 0 ? body.substring(n + 2) : '',
      signature(body) == sms.substring(k + 2));
  if (type == 'Q') {
    final f = {for (final p in items) p[0]: p.substring(1)};
    final e = RegExp(r'^(\d+)([OFX]?)$').firstMatch(f['E'] ?? '0');
    reply.storm = Storm(f['W'] ?? '', int.tryParse(f['R'] ?? '') ?? 0, int.tryParse(f['G'] ?? '') ?? 0,
        e != null ? int.parse(e.group(1)!) : 0, e?.group(2) ?? '', int.tryParse(f['C'] ?? '') ?? 0);
  } else {
    for (final part in items) {
      final item = _parseField(type, part);
      if (item == null) return null;
      reply.items.add(item);
    }
  }
  return reply;
}
