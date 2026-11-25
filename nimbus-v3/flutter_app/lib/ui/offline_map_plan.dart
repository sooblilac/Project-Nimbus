import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart';

import '../data/philippine_location.dart';

const maxOfflineMapTiles = 3000;
const maxOfflineMapDownloadBytes = 45000000;

LatLngBounds philippinesOverviewBounds(PhilippineOutline outline) =>
    LatLngBounds(
      southwest: LatLng(outline.bounds.top, outline.bounds.left),
      northeast: LatLng(outline.bounds.bottom, outline.bounds.right),
    );

LatLngBounds locationDetailBounds(PhilippineLocation location) => LatLngBounds(
  southwest: LatLng(
    math.max(-85.05112878, location.latitude - 0.15).toDouble(),
    math.max(-180, location.longitude - 0.15).toDouble(),
  ),
  northeast: LatLng(
    math.min(85.05112878, location.latitude + 0.15).toDouble(),
    math.min(180, location.longitude + 0.15).toDouble(),
  ),
);

int estimateOfflineTileCount(
  LatLngBounds bounds, {
  required int minZoom,
  required int maxZoom,
}) {
  if (minZoom < 0 || maxZoom < minZoom) {
    throw ArgumentError('Zoom range must be non-negative and ordered.');
  }

  var total = 0;
  for (var zoom = minZoom; zoom <= maxZoom; zoom++) {
    final tilesPerAxis = 1 << zoom;
    final west = _tileX(bounds.southwest.longitude, tilesPerAxis);
    final east = _tileX(bounds.northeast.longitude, tilesPerAxis);
    final north = _tileY(bounds.northeast.latitude, tilesPerAxis);
    final south = _tileY(bounds.southwest.latitude, tilesPerAxis);
    final xCount =
        east >= west ? east - west + 1 : (tilesPerAxis - west) + east + 1;
    total += xCount * (south - north + 1);
  }
  return total;
}

int _tileX(double longitude, int tilesPerAxis) {
  final normalized = ((longitude + 180) / 360).clamp(0.0, 1.0);
  return (normalized * tilesPerAxis).floor().clamp(0, tilesPerAxis - 1).toInt();
}

int _tileY(double latitude, int tilesPerAxis) {
  final radians = latitude.clamp(-85.05112878, 85.05112878) * math.pi / 180;
  final mercatorY =
      (1 - math.log(math.tan(math.pi / 4 + radians / 2)) / math.pi) / 2;
  return (mercatorY * tilesPerAxis).floor().clamp(0, tilesPerAxis - 1).toInt();
}
