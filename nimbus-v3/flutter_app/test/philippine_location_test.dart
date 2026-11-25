import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus/data/philippine_location.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offline location catalog coordinates fit the bundled map bounds',
      () async {
    final locations = await loadPhilippineLocations();
    final outline = await loadPhilippineOutline();

    expect(locations.length, greaterThan(1600));
    for (final location in locations) {
      expect(
        outline.bounds.contains(Offset(location.longitude, location.latitude)),
        isTrue,
        reason: '${location.name}, ${location.province} is outside the map',
      );
    }

    expect(
      locations.any((location) =>
          location.name == 'Kalayaan' &&
          location.province == 'Palawan' &&
          location.longitude < 116),
      isTrue,
    );
    expect(
      locations
          .singleWhere((location) =>
              location.name == 'Alicia' &&
              location.province == 'Zamboanga Sibugay')
          .latitude,
      lessThan(10),
    );
    expect(
      locations
          .singleWhere((location) =>
              location.name == 'Maragusan' &&
              location.province == 'Davao De Oro')
          .latitude,
      lessThan(10),
    );
    await rootBundle.load('assets/images/nmbus_mark.png');
  });

}
