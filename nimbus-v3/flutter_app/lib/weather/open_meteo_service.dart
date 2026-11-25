import 'dart:async';
import 'dart:convert';
import 'dart:io';

class OpenMeteoService {
  static const _timeout = Duration(seconds: 12);

  Future<WeatherSnapshot> current({
    required double latitude,
    required double longitude,
  }) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current':
            'temperature_2m,relative_humidity_2m,apparent_temperature,'
            'precipitation,weather_code,wind_speed_10m,wind_gusts_10m',
        'timezone': 'auto',
      });
      final request = await client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      final body = await utf8.decoder.bind(response).join().timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OpenMeteoException(
          'Weather service request failed (${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Weather response must be an object.');
      }
      return WeatherSnapshot.fromJson(decoded);
    } on SocketException {
      throw const OpenMeteoException(
        'Could not reach Open-Meteo. Check the internet connection.',
      );
    } on TimeoutException {
      throw const OpenMeteoException('Open-Meteo did not respond in time.');
    } on HttpException catch (error) {
      throw OpenMeteoException('Weather network error: ${error.message}');
    } on FormatException catch (error) {
      throw OpenMeteoException(
        'Open-Meteo returned invalid data: ${error.message}',
      );
    } finally {
      client.close(force: true);
    }
  }
}

class WeatherSnapshot {
  const WeatherSnapshot({
    required this.temperatureC,
    required this.apparentTemperatureC,
    required this.humidityPercent,
    required this.precipitationMm,
    required this.windKph,
    required this.gustKph,
    required this.description,
    required this.observedAt,
  });

  final double temperatureC;
  final double apparentTemperatureC;
  final int humidityPercent;
  final double precipitationMm;
  final double windKph;
  final double gustKph;
  final String description;
  final DateTime observedAt;

  factory WeatherSnapshot.fromJson(Map<String, dynamic> json) {
    final current = json['current'];
    if (current is! Map<String, dynamic>) {
      throw const FormatException('Current weather is missing.');
    }
    final humidity = _number(current, 'relative_humidity_2m');
    final code = _number(current, 'weather_code').round();
    if (humidity < 0 || humidity > 100) {
      throw const FormatException('Humidity is outside the expected range.');
    }
    return WeatherSnapshot(
      temperatureC: _number(current, 'temperature_2m'),
      apparentTemperatureC: _number(current, 'apparent_temperature'),
      humidityPercent: humidity.round(),
      precipitationMm: _number(current, 'precipitation'),
      windKph: _number(current, 'wind_speed_10m'),
      gustKph: _number(current, 'wind_gusts_10m'),
      description: _weatherDescription(code),
      observedAt: DateTime.parse(_string(current, 'time')),
    );
  }
}

class OpenMeteoException implements Exception {
  const OpenMeteoException(this.message);

  final String message;

  @override
  String toString() => message;
}

double _number(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is num && value.isFinite) return value.toDouble();
  throw FormatException('Current weather has an invalid $field.');
}

String _string(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is String) return value;
  throw FormatException('Current weather is missing $field.');
}

String _weatherDescription(int code) => switch (code) {
  0 => 'Clear sky',
  1 => 'Mainly clear',
  2 => 'Partly cloudy',
  3 => 'Overcast',
  45 || 48 => 'Fog',
  51 || 53 || 55 => 'Drizzle',
  56 || 57 => 'Freezing drizzle',
  61 || 63 || 65 => 'Rain',
  66 || 67 => 'Freezing rain',
  71 || 73 || 75 || 77 => 'Snow',
  80 || 81 || 82 => 'Rain showers',
  85 || 86 => 'Snow showers',
  95 => 'Thunderstorm',
  96 || 99 => 'Thunderstorm with hail',
  _ => 'Weather conditions unavailable',
};
