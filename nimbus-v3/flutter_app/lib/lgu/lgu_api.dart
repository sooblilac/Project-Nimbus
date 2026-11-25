import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FloodAreaUpdate {
  const FloodAreaUpdate({
    required this.name,
    required this.level,
    required this.status,
  });

  final String name;
  final String level;
  final String status;

  factory FloodAreaUpdate.fromJson(Map<String, dynamic> json) {
    final name = _requiredString(json, 'name');
    final level = _requiredString(json, 'level');
    final status = _requiredString(json, 'status');
    if (name.trim().isEmpty ||
        !{'H', 'M', 'L'}.contains(level) ||
        !{'F', 'W', 'C'}.contains(status)) {
      throw const FormatException(
        'The API response has an invalid flood area.',
      );
    }
    return FloodAreaUpdate(name: name, level: level, status: status);
  }

  Map<String, Object> toJson() => {
    'name': name,
    'level': level,
    'status': status,
  };
}

class EvacuationCenterUpdate {
  const EvacuationCenterUpdate({
    required this.name,
    required this.status,
    required this.percentFull,
  });

  final String name;
  final String status;
  final int percentFull;

  factory EvacuationCenterUpdate.fromJson(Map<String, dynamic> json) {
    final name = _requiredString(json, 'name');
    final status = _requiredString(json, 'status');
    final percentFull = _requiredInt(json, 'percentFull');
    if (name.trim().isEmpty ||
        !{'O', 'F', 'X'}.contains(status) ||
        percentFull < 0 ||
        percentFull > 100) {
      throw const FormatException(
        'The API response has an invalid evacuation center.',
      );
    }
    return EvacuationCenterUpdate(
      name: name,
      status: status,
      percentFull: percentFull,
    );
  }

  Map<String, Object> toJson() => {
    'name': name,
    'status': status,
    'percentFull': percentFull,
  };
}

class RoadStatusUpdate {
  const RoadStatusUpdate({required this.name, required this.status});

  final String name;
  final String status;

  factory RoadStatusUpdate.fromJson(Map<String, dynamic> json) {
    final name = _requiredString(json, 'name');
    final status = _requiredString(json, 'status');
    if (name.trim().isEmpty || !{'O', 'L', 'X'}.contains(status)) {
      throw const FormatException(
        'The API response has an invalid road status.',
      );
    }
    return RoadStatusUpdate(name: name, status: status);
  }

  Map<String, Object> toJson() => {'name': name, 'status': status};
}

class MapPinUpdate {
  const MapPinUpdate({
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

  factory MapPinUpdate.fromJson(Map<String, dynamic> json) {
    final category = _requiredString(json, 'category');
    final label = _requiredString(json, 'label');
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    final status = _requiredString(json, 'status');
    final intensity = _requiredInt(json, 'intensity');
    final validStatus = switch (category) {
      'flood' => {'F', 'W', 'C'}.contains(status),
      'evacuation' => {'O', 'F', 'X'}.contains(status),
      'road' => {'O', 'L', 'X'}.contains(status),
      _ => false,
    };
    if (label.trim().isEmpty ||
        latitude is! num ||
        longitude is! num ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180 ||
        !validStatus ||
        intensity < 0 ||
        intensity > 100) {
      throw const FormatException('The API response has an invalid map pin.');
    }
    return MapPinUpdate(
      category: category,
      label: label,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      status: status,
      intensity: intensity,
    );
  }

  Map<String, Object> toJson() => {
    'category': category,
    'label': label,
    'latitude': latitude,
    'longitude': longitude,
    'status': status,
    'intensity': intensity,
  };
}

class MapPinLocationSelection {
  const MapPinLocationSelection({
    required this.requestId,
    required this.category,
    required this.label,
    required this.latitude,
    required this.longitude,
  });

  final int requestId;
  final String category;
  final String label;
  final double latitude;
  final double longitude;
}

class LguUpdate {
  const LguUpdate({
    required this.townCode,
    required this.classes,
    required this.notice,
    required this.floodAreas,
    required this.evacuationCenters,
    this.roadStatuses = const [],
    this.mapPins = const [],
    required this.updatedAt,
  });

  final String townCode;
  final int classes;
  final String notice;
  final List<FloodAreaUpdate> floodAreas;
  final List<EvacuationCenterUpdate> evacuationCenters;
  final List<RoadStatusUpdate> roadStatuses;
  final List<MapPinUpdate> mapPins;
  final DateTime updatedAt;

  factory LguUpdate.fromJson(Map<String, dynamic> json) {
    final floodAreas = json['floodAreas'];
    final evacuationCenters = json['evacuationCenters'];
    final roadStatuses = json['roadStatuses'] ?? const [];
    final mapPins = json['mapPins'] ?? const [];
    final townCode = _requiredString(json, 'townCode');
    final classes = _requiredInt(json, 'classes');
    if (floodAreas is! List ||
        evacuationCenters is! List ||
        roadStatuses is! List ||
        mapPins is! List) {
      throw const FormatException(
        'The API response is missing flood, evacuation, or road status.',
      );
    }
    if (!RegExp(r'^(?:\d{4}|\d{10})$').hasMatch(townCode) ||
        classes < 0 ||
        classes > 5) {
      throw const FormatException(
        'The API response has an invalid town or class status.',
      );
    }
    return LguUpdate(
      townCode: townCode,
      classes: classes,
      notice: _requiredString(json, 'notice'),
      floodAreas: [
        for (final item in floodAreas)
          FloodAreaUpdate.fromJson(_requiredObject(item, 'flood area')),
      ],
      evacuationCenters: [
        for (final item in evacuationCenters)
          EvacuationCenterUpdate.fromJson(
            _requiredObject(item, 'evacuation center'),
          ),
      ],
      roadStatuses: [
        for (final item in roadStatuses)
          RoadStatusUpdate.fromJson(_requiredObject(item, 'road status')),
      ],
      mapPins: [
        for (final item in mapPins)
          MapPinUpdate.fromJson(_requiredObject(item, 'map pin')),
      ],
      updatedAt: DateTime.parse(_requiredString(json, 'updatedAt')),
    );
  }

  Map<String, Object> toJson() => {
    'classes': classes,
    'notice': notice,
    'floodAreas': [for (final area in floodAreas) area.toJson()],
    'evacuationCenters': [
      for (final center in evacuationCenters) center.toJson(),
    ],
    'roadStatuses': [for (final road in roadStatuses) road.toJson()],
    'mapPins': [for (final pin in mapPins) pin.toJson()],
  };
}

class LguApiException implements Exception {
  const LguApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LguSession {
  const LguSession({
    required this.accessToken,
    required this.username,
    required this.townCodes,
  });

  final String accessToken;
  final String username;
  final List<String> townCodes;
}

class LguApiService {
  LguApiService({Uri? baseUri})
    : _baseUri =
          baseUri ??
          Uri.parse(
            const String.fromEnvironment(
              'NIMBUS_API_URL',
              defaultValue: 'http://10.0.2.2:8080/api',
            ),
          );

  final Uri _baseUri;
  static const _timeout = Duration(seconds: 12);
  late final _PublisherCredentials _publisherCredentials =
      _loadPublisherCredentials();

  String? publisherSetupMessage(String townCode, {String? accessToken}) {
    if (accessToken != null && accessToken.isNotEmpty) return null;
    final credentials = _publisherCredentials;
    return credentials.error ??
        (credentials.tokens.containsKey(townCode)
            ? null
            : 'Publishing is not configured for this town. Contact your NIMBUS administrator.');
  }

  Future<LguSession> login(String username, String password) async {
    final response = await _send(
      'POST',
      'auth/login',
      body: {'username': username, 'password': password},
    );
    final accessToken = response['accessToken'];
    final signedInUsername = response['username'];
    final townCodes = response['townCodes'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        signedInUsername is! String ||
        townCodes is! List ||
        townCodes.any((code) => code is! String)) {
      throw const FormatException(
        'The login response is missing valid session details.',
      );
    }
    return LguSession(
      accessToken: accessToken,
      username: signedInUsername,
      townCodes: townCodes.cast<String>(),
    );
  }

  Future<void> logout(String accessToken) async {
    await _send('POST', 'auth/logout', token: accessToken, body: const {});
  }

  Future<void> deleteTown(
    String townCode, {
    required String accessToken,
  }) async {
    final response = await _request('DELETE', townCode, token: accessToken);
    if (response['ok'] != true) {
      throw const FormatException(
        'The API did not confirm the town update reset.',
      );
    }
  }

  Future<LguUpdate?> fetchTown(String townCode) async {
    final response = await _request('GET', townCode);
    if (!response.containsKey('update')) {
      throw const FormatException(
        'The API response is missing the update field.',
      );
    }
    final value = response['update'];
    if (value == null) return null;
    final update = LguUpdate.fromJson(_requiredObject(value, 'update'));
    if (update.townCode != townCode) {
      throw const FormatException(
        'The API returned an update for a different town.',
      );
    }
    return update;
  }

  Future<LguUpdate> publish(
    String townCode,
    LguUpdate draft, {
    String? accessToken,
  }) async {
    final token = accessToken ?? _publisherCredentials.tokens[townCode];
    if (token == null) {
      throw LguApiException(
        publisherSetupMessage(townCode) ??
            'Publishing is not configured for this town.',
      );
    }
    final response = await _request(
      'POST',
      townCode,
      token: token,
      body: draft.toJson(),
    );
    final update = LguUpdate.fromJson(
      _requiredObject(response['update'], 'update'),
    );
    if (update.townCode != townCode) {
      throw const FormatException(
        'The API returned an update for a different town.',
      );
    }

    return update;
  }

  _PublisherCredentials _loadPublisherCredentials() {
    const raw = String.fromEnvironment('NIMBUS_LGU_TOKENS');
    if (raw.isEmpty) return const _PublisherCredentials({});

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      return _PublisherCredentials(
        const {},
        error: 'LGU publishing configuration is invalid: ${error.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      return const _PublisherCredentials(
        {},
        error: 'LGU publishing configuration must be a JSON object.',
      );
    }

    final tokens = <String, String>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (!RegExp(r'^(?:\d{4}|\d{10})$').hasMatch(entry.key) ||
          value is! String ||
          value.length < 32) {
        return const _PublisherCredentials(
          {},
          error: 'LGU publishing configuration contains an invalid entry.',
        );
      }
      tokens[entry.key] = value;
    }
    return _PublisherCredentials(tokens);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String townCode, {
    String? token,
    Map<String, Object>? body,
  }) => _send(method, 'towns/$townCode/updates', token: token, body: body);

  Future<Map<String, dynamic>> _send(
    String method,
    String endpoint, {
    String? token,
    Map<String, Object>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final path = '${_baseUri.path.replaceFirst(RegExp(r'/$'), '')}/$endpoint';
      final request = await client
          .openUrl(method, _baseUri.replace(path: path))
          .timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      final response = await request.close().timeout(_timeout);
      final text = await utf8.decoder.bind(response).join().timeout(_timeout);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('The API returned an invalid response.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw LguApiException(
          decoded['error'] is String
              ? decoded['error'] as String
              : 'API request failed (${response.statusCode}).',
        );
      }
      return decoded;
    } on SocketException {
      throw const LguApiException(
        'Could not reach the Nimbus API. Check the server address and network.',
      );
    } on HandshakeException {
      throw const LguApiException(
        'Could not establish a secure connection to the Nimbus API.',
      );
    } on HttpException catch (error) {
      throw LguApiException('Nimbus API network error: ${error.message}');
    } on TimeoutException {
      throw const LguApiException('The Nimbus API did not respond in time.');
    } on FormatException catch (error) {
      throw LguApiException(
        'The Nimbus API returned invalid data: ${error.message}',
      );
    } finally {
      client.close(force: true);
    }
  }
}

class _PublisherCredentials {
  const _PublisherCredentials(this.tokens, {this.error});

  final Map<String, String> tokens;
  final String? error;
}

Map<String, dynamic> _requiredObject(Object? value, String field) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('The API response has an invalid $field.');
}

String _requiredString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is String) return value;
  throw FormatException('The API response has an invalid $field.');
}

int _requiredInt(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is int) return value;
  throw FormatException('The API response has an invalid $field.');
}
