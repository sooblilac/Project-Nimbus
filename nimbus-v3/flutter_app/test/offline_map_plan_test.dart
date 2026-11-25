import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:nimbus/data/philippine_location.dart';
import 'package:nimbus/ui/offline_map_plan.dart';

void main() {
  const outline = PhilippineOutline(
    bounds: Rect.fromLTRB(114.277902, 4.655707, 126.617686, 21.122382),
    islands: [],
  );
  const location = PhilippineLocation(
    code: '0421060000',
    name: 'Manila',
    province: 'Metro Manila',
    region: 'NCR',
    islandGroup: 'Luzon',
    kind: 'city',
    latitude: 14.5995,
    longitude: 120.9842,
  );

  test('country overview and town detail fit the per-download tile limit', () {
    final overview = philippinesOverviewBounds(outline);
    final detail = locationDetailBounds(location);

    expect(
      estimateOfflineTileCount(overview, minZoom: 3, maxZoom: 7),
      lessThanOrEqualTo(maxOfflineMapTiles),
    );
    expect(
      estimateOfflineTileCount(detail, minZoom: 9, maxZoom: 15),
      lessThanOrEqualTo(maxOfflineMapTiles),
    );
  });

  test('large requested areas are detected before downloading', () {
    final world = LatLngBounds(
      southwest: const LatLng(-85, -180),
      northeast: const LatLng(85, 179.999),
    );

    expect(
      estimateOfflineTileCount(world, minZoom: 0, maxZoom: 6),
      greaterThan(maxOfflineMapTiles),
    );
  });
}
