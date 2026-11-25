// Nimbus SMS format NB1 for the Flutter app. Mirrors nimbus-codec.js line for line.
//
//   NB1 <type> <town> <field> ... T<hhmm> [/<notice>] K<signature>
//   NB1~P~<town>~<pin>...~T<hhmm>~K<signature> (multipart-safe pin snapshot)
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
String cleanNotice(String text) =>
    text
        .replaceAll(RegExp('[‘’]'), "'")
        .replaceAll(RegExp('[“”]'), '"')
        .replaceAll(RegExp('[–—]'), '-')
        .replaceAll(RegExp(r'[^\x20-\x7E]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

String encode(
  String type,
  String townCode,
  List<String> fields,
  String time, [
  String notice = '',
]) {
  var body = [nbVersion, type, townCode, ...fields, 'T$time'].join(' ');
  if (notice.isNotEmpty) body += ' /$notice';
  return '$body K${signature(body)}';
}

class MapPin {
  const MapPin({
    required this.category,
    required this.label,
    required this.latitude,
    required this.longitude,
    required this.status,
    required this.intensity,
  });

  final String category;
  final String label;
  final double latitude;
  final double longitude;
  final String status;
  final int intensity;
}

String encodePins(String townCode, List<MapPin> pins, String time) {
  if (!RegExp(r'^(?:\d{4}|\d{10})$').hasMatch(townCode)) {
    throw ArgumentError.value(townCode, 'townCode');
  }
  final fields = <String>[];
  for (final pin in pins) {
    final category = switch (pin.category) {
      'flood' => 'F',
      'evacuation' => 'E',
      'road' => 'R',
      _ => throw ArgumentError.value(pin.category, 'category'),
    };
    final validStatus = switch (category) {
      'F' => {'F', 'W', 'C'}.contains(pin.status),
      'E' => {'O', 'F', 'X'}.contains(pin.status),
      _ => {'O', 'L', 'X'}.contains(pin.status),
    };
    if (!validStatus ||
        pin.intensity < 0 ||
        pin.intensity > 100 ||
        !pin.latitude.isFinite ||
        !pin.longitude.isFinite ||
        pin.latitude < -90 ||
        pin.latitude > 90 ||
        pin.longitude < -180 ||
        pin.longitude > 180) {
      throw ArgumentError('Invalid map pin: ${pin.label}');
    }
    final label = cleanNotice(
      pin.label,
    ).replaceAll('|', ' ').replaceAll(RegExp(r'\s+'), '_');
    if (label.isEmpty) throw ArgumentError('Map pin labels cannot be empty.');
    fields.add(
      '$category|${pin.status}|${pin.intensity}|'
      '${(pin.latitude * 100000).round()}|'
      '${(pin.longitude * 100000).round()}|$label',
    );
  }
  final body = [nbVersion, 'P', townCode, ...fields, 'T$time'].join('~');
  return '$body~K${signature(body)}';
}

class Storm {
  const Storm(
    this.warning,
    this.rain,
    this.gusts,
    this.evacSite,
    this.evacStatus,
    this.classes,
  );
  final String warning;
  final int rain;
  final int gusts;
  final int evacSite;
  final String evacStatus;
  final int classes;
}

class Item {
  const Item(
    this.index, {
    this.level,
    this.now,
    this.status,
    this.percentFull,
    this.customName,
  });
  final int index;
  final String? level;
  final String? now;
  final String? status;
  final int? percentFull;
  final String? customName;
}

class Reply {
  Reply(
    this.version,
    this.type,
    this.townCode,
    this.time,
    this.notice,
    this.valid,
  );
  final String version;
  final String type;
  final String townCode;
  final String time;
  final String notice;
  final bool valid;
  Storm? storm;
  final List<Item> items = [];
  final List<MapPin> pins = [];
}

final _flood = RegExp(r'^A(\d+)([HML])([FWC])(?::(\S+))?$');
final _evac = RegExp(r'^S(\d+)([OFX])(\d+)$');
final _road = RegExp(r'^R(\d+)([OLX])(?::(\S+))?$');
final _pin = RegExp(
  r"^([FER])\|([A-Z])\|(\d{1,3})\|(-?\d{1,8})\|(-?\d{1,9})\|([A-Za-z0-9_.'-]+)$",
);

MapPin? _parsePin(String part) {
  final match = _pin.firstMatch(part);
  if (match == null) return null;
  final categoryCode = match.group(1)!;
  final status = match.group(2)!;
  final intensity = int.parse(match.group(3)!);
  final latitude = int.parse(match.group(4)!);
  final longitude = int.parse(match.group(5)!);
  final validStatus = switch (categoryCode) {
    'F' => {'F', 'W', 'C'}.contains(status),
    'E' => {'O', 'F', 'X'}.contains(status),
    _ => {'O', 'L', 'X'}.contains(status),
  };
  if (!validStatus ||
      intensity > 100 ||
      latitude.abs() > 9000000 ||
      longitude.abs() > 18000000) {
    return null;
  }
  return MapPin(
    category: switch (categoryCode) {
      'F' => 'flood',
      'E' => 'evacuation',
      _ => 'road',
    },
    label: match.group(6)!.replaceAll('_', ' '),
    latitude: latitude / 100000,
    longitude: longitude / 100000,
    status: status,
    intensity: intensity,
  );
}

Item? _parseField(String type, String part) {
  RegExpMatch? m;
  if (type == 'F' && (m = _flood.firstMatch(part)) != null) {
    return Item(
      int.parse(m!.group(1)!),
      level: m.group(2),
      now: m.group(3),
      customName: m.group(4)?.replaceAll('_', ' '),
    );
  }
  if (type == 'E' && (m = _evac.firstMatch(part)) != null) {
    return Item(
      int.parse(m!.group(1)!),
      status: m.group(2),
      percentFull: int.parse(m.group(3)!),
    );
  }
  if (type == 'R' && (m = _road.firstMatch(part)) != null) {
    return Item(
      int.parse(m!.group(1)!),
      status: m.group(2),
      customName: m.group(3)?.replaceAll('_', ' '),
    );
  }
  return null;
}

/// Returns null for anything that isn't an NB1 reply, so a stray text never crashes the app.
Reply? decode(String sms) {
  final compactPins = sms.startsWith('$nbVersion~P~');
  final marker = compactPins ? '~K' : ' K';
  final k = sms.lastIndexOf(marker);
  if (k < 0 || !sms.startsWith('$nbVersion${compactPins ? '~' : ' '}')) {
    return null;
  }
  final body = sms.substring(0, k);
  final n = body.indexOf(' /');
  final parts =
      (n >= 0 ? body.substring(0, n) : body).split(compactPins ? '~' : ' ');
  if (parts.length < 4) return null;
  final type = parts[1];
  if (type == 'P' &&
      !RegExp(r'^(?:\d{4}|\d{10})$').hasMatch(parts[2])) {
    return null;
  }
  final items = parts.sublist(3, parts.length - 1);
  final timePart = parts.last;
  if (!RegExp(r'^T\d{4}$').hasMatch(timePart)) return null;
  final reply = Reply(
    parts[0],
    type,
    parts[2],
    timePart.substring(1),
    n >= 0 ? body.substring(n + 2) : '',
    signature(body) == sms.substring(k + marker.length),
  );
  if (type == 'Q') {
    final f = {for (final p in items) p[0]: p.substring(1)};
    final e = RegExp(r'^(\d+)([OFX]?)$').firstMatch(f['E'] ?? '0');
    reply.storm = Storm(
      f['W'] ?? '',
      int.tryParse(f['R'] ?? '') ?? 0,
      int.tryParse(f['G'] ?? '') ?? 0,
      e != null ? int.parse(e.group(1)!) : 0,
      e?.group(2) ?? '',
      int.tryParse(f['C'] ?? '') ?? 0,
    );
  } else if (type == 'P') {
    for (final part in items) {
      final pin = _parsePin(part);
      if (pin == null) return null;
      reply.pins.add(pin);
    }
  } else {
    for (final part in items) {
      final item = _parseField(type, part);
      if (item == null) return null;
      reply.items.add(item);
    }
  }
  return reply;
}
