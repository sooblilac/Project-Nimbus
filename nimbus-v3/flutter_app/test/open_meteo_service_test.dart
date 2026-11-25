import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus/weather/open_meteo_service.dart';

void main() {
  test('parses current local weather and describes WMO conditions', () {
    final snapshot = WeatherSnapshot.fromJson({
      'current': {
        'time': '2026-11-25T10:15',
        'temperature_2m': 29.4,
        'relative_humidity_2m': 78,
        'apparent_temperature': 34.1,
        'precipitation': 1.2,
        'weather_code': 95,
        'wind_speed_10m': 18.5,
        'wind_gusts_10m': 27.1,
      },
    });

    expect(snapshot.description, 'Thunderstorm');
    expect(snapshot.temperatureC, 29.4);
    expect(snapshot.humidityPercent, 78);
    expect(snapshot.gustKph, 27.1);
  });

  test('rejects malformed current conditions', () {
    expect(
      () => WeatherSnapshot.fromJson({'current': {}}),
      throwsFormatException,
    );
  });
}
