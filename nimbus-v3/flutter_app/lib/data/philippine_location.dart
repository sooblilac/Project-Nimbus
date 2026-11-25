import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';

class PhilippineLocation {
  const PhilippineLocation({
    required this.code,
    required this.name,
    required this.province,
    required this.region,
    required this.islandGroup,
    required this.kind,
    required this.latitude,
    required this.longitude,
    this.legacyCode,
  });

  final String code;
  final String name;
  final String province;
  final String region;
  final String islandGroup;
  final String kind;
  final double latitude;
  final double longitude;
  final String? legacyCode;

  String get smsCode => legacyCode ?? code;
  String get contextLabel => province.isEmpty ? region : '$province · $region';
  String get searchLabel => '$name · $contextLabel';

  factory PhilippineLocation.fromJson(Map<String, dynamic> json) {
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    final code = _string(json, 'code');
    if (!RegExp(r'^\d{10}$').hasMatch(code) ||
        latitude is! num ||
        longitude is! num ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException('The bundled location catalog has invalid coordinates.');
    }
    return PhilippineLocation(
      code: code,
      name: _string(json, 'name'),
      province: _string(json, 'province'),
      region: _string(json, 'region'),
      islandGroup: _string(json, 'islandGroup'),
      kind: _string(json, 'kind'),
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      legacyCode: json['legacyCode'] as String?,
    );
  }
}

class PhilippineOutline {
  const PhilippineOutline({required this.bounds, required this.islands});

  final Rect bounds;
  final List<List<Offset>> islands;

  factory PhilippineOutline.fromJson(Map<String, dynamic> json) {
    final bounds = json['bounds'];
    final polygons = json['polygons'];
    if (bounds is! List || bounds.length != 4 || polygons is! List) {
      throw const FormatException('The bundled Philippines map is invalid.');
    }
    final boundsNumbers = bounds.whereType<num>().toList();
    if (boundsNumbers.length != 4) {
      throw const FormatException('The bundled Philippines map has invalid bounds.');
    }
    return PhilippineOutline(
      bounds: Rect.fromLTRB(
        boundsNumbers[0].toDouble(),
        boundsNumbers[1].toDouble(),
        boundsNumbers[2].toDouble(),
        boundsNumbers[3].toDouble(),
      ),
      islands: [
        for (final polygon in polygons)
          _readRing(polygon),
      ],
    );
  }
}

Future<List<PhilippineLocation>> loadPhilippineLocations() async {
  final json = jsonDecode(
    await rootBundle.loadString('assets/data/philippine_locations.json'),
  );
  if (json is! List) {
    throw const FormatException('The bundled Philippine location catalog is invalid.');
  }
  final locations = [
    for (final item in json)
      PhilippineLocation.fromJson(_object(item)),
  ];
  if (locations.isEmpty) {
    throw const FormatException('The bundled Philippine location catalog is empty.');
  }
  return locations;
}

Future<PhilippineOutline> loadPhilippineOutline() async {
  final json = jsonDecode(
    await rootBundle.loadString('assets/data/philippines_outline.json'),
  );
  return PhilippineOutline.fromJson(_object(json));
}

Map<String, dynamic> _object(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('The bundled Philippines data contains an invalid entry.');
}

List<Offset> _readRing(Object? value) {
  if (value is! List || value.length < 4) {
    throw const FormatException('The bundled Philippines map contains an invalid island.');
  }
  return [
    for (final point in value)
      if (point is List && point.length == 2 && point[0] is num && point[1] is num)
        Offset((point[0] as num).toDouble(), (point[1] as num).toDouble())
      else
        throw const FormatException('The bundled Philippines map contains an invalid coordinate.'),
  ];
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('The bundled location is missing $key.');
}
