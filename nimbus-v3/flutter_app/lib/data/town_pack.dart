import 'dart:ui';

/// The offline town pack that ships inside the app. SMS replies only carry short codes
/// (area 2, site 1, road 3), so names and map shapes live here. Sample data, not real hazard maps.
class Town {
  const Town({
    required this.code,
    required this.name,
    required this.floodAreas,
    required this.sites,
    required this.roads,
    required this.river,
    required this.zones,
    required this.stormAt,
    required this.stormTrack,
    required this.warnings,
  });

  final String code;
  final String name;
  final List<String> floodAreas;
  final List<String> sites;
  final List<String> roads;

  /// River as points in town-pack coordinates (360 x 800 drawing, town in the middle band).
  final List<Offset> river;

  /// Flood zone ellipses: centre and radii, by area number.
  final List<Rect> zones;

  /// Sample storm position and past track, oldest first.
  final Offset stormAt;
  final List<Offset> stormTrack;

  /// Warning code from the reply (W field) to headline and detail.
  final Map<String, (String, String)> warnings;
}

const _signals = {
  '1': ('Signal No. 1', 'Strong winds within 36 hours'),
  '2': ('Signal No. 2', 'Gale-force winds within 24 hours'),
  'F': ('Flood advisory', 'Rivers may overflow in low-lying areas'),
};

const towns = <Town>[
  Town(
    code: '0412', name: 'Batangas City',
    floodAreas: ['Riverbank zone', 'Coastal strip', 'Market area', 'Upland barangays'],
    sites: ['Central School', 'City Gym', 'Parish Hall'],
    roads: ['National highway', 'Riverside road', 'Port access road'],
    river: [Offset(170, 150), Offset(178, 220), Offset(160, 280), Offset(150, 360)],
    zones: [Rect.fromLTRB(136, 232, 196, 268), Rect.fromLTRB(64, 318, 156, 342), Rect.fromLTRB(210, 284, 270, 316), Rect.fromLTRB(32, 220, 108, 260)],
    stormAt: Offset(232, 170), stormTrack: [Offset(300, 300), Offset(282, 262), Offset(262, 228), Offset(246, 198)],
    warnings: _signals,
  ),
  Town(
    code: '0517', name: 'Naga City',
    floodAreas: ['Riverside barangays', 'Downtown low area', 'Bypass road area', 'Hillside barangays'],
    sites: ['City Sports Complex', 'Central School', 'Barangay Covered Court'],
    roads: ['Main bridge', 'Diversion road', 'North highway'],
    river: [Offset(0, 262), Offset(100, 262), Offset(200, 284), Offset(300, 266)],
    zones: [Rect.fromLTRB(54, 244, 126, 280), Rect.fromLTRB(162, 282, 230, 318), Rect.fromLTRB(232, 220, 292, 252), Rect.fromLTRB(36, 312, 116, 348)],
    stormAt: Offset(238, 162), stormTrack: [Offset(306, 288), Offset(288, 252), Offset(268, 220), Offset(252, 190)],
    warnings: _signals,
  ),
  Town(
    code: '0837', name: 'Tacloban City',
    floodAreas: ['Coastal barangays', 'Downtown', 'Airport road area', 'Upland barangays'],
    sites: ['Convention Center', 'Central School'],
    roads: ['Coastal road', 'Downtown streets', 'Airport road'],
    river: [Offset(244, 150), Offset(244, 220), Offset(238, 300)],
    zones: [Rect.fromLTRB(96, 318, 216, 342), Rect.fromLTRB(170, 264, 230, 300), Rect.fromLTRB(66, 272, 134, 308), Rect.fromLTRB(42, 220, 122, 256)],
    stormAt: Offset(244, 156), stormTrack: [Offset(310, 280), Offset(292, 244), Offset(274, 212), Offset(258, 182)],
    warnings: _signals,
  ),
  Town(
    code: '1374', name: 'Marikina City',
    floodAreas: ['Riverbank barangays', 'Riverside park area', 'Low-lying subdivisions', 'Hillside barangays'],
    sites: ['Barangay Covered Court', 'Elementary School', 'Sports Center'],
    roads: ['River bridge', 'Riverside drive', 'Main avenue', 'Hillside road'],
    river: [Offset(128, 150), Offset(130, 230), Offset(150, 280), Offset(132, 330)],
    zones: [Rect.fromLTRB(98, 188, 158, 232), Rect.fromLTRB(118, 278, 174, 322), Rect.fromLTRB(184, 260, 264, 300), Rect.fromLTRB(206, 202, 286, 238)],
    stormAt: Offset(228, 176), stormTrack: [Offset(296, 306), Offset(278, 268), Offset(258, 234), Offset(242, 204)],
    warnings: _signals,
  ),
];

Town townByCode(String code) => towns.firstWhere((t) => t.code == code, orElse: () => towns.first);
