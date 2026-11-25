import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus/codec/nimbus_codec.dart' as codec;
import 'package:nimbus/data/town_pack.dart';
import 'package:nimbus/lgu/lgu_api.dart';
import 'package:nimbus/sms/sms_service.dart';
import 'package:nimbus/ui/lgu_console.dart';

void main() {
  test('serializes and restores the shared town status', () {
    final update = LguUpdate(
      townCode: '0412',
      classes: 1,
      notice: 'Avoid the riverside',
      floodAreas: const [
        FloodAreaUpdate(name: 'Riverbank zone', level: 'H', status: 'F'),
      ],
      evacuationCenters: const [
        EvacuationCenterUpdate(
          name: 'Central School',
          status: 'O',
          percentFull: 45,
        ),
      ],
      roadStatuses: const [
        RoadStatusUpdate(name: 'Riverside road', status: 'L'),
      ],
      mapPins: const [
        MapPinUpdate(
          category: 'flood',
          label: 'Market crossing',
          latitude: 13.7563,
          longitude: 121.0583,
          status: 'F',
          intensity: 95,
        ),
      ],
      updatedAt: DateTime.utc(2026, 11, 25),
    );

    final payload = update.toJson();
    expect(payload['floodAreas'], [
      {'name': 'Riverbank zone', 'level': 'H', 'status': 'F'},
    ]);
    final restored = LguUpdate.fromJson({
      ...payload,
      'townCode': '0412',
      'updatedAt': '2026-11-25T02:00:00.000Z',
    });
    expect(restored.evacuationCenters.single.percentFull, 45);
    expect(restored.roadStatuses.single.status, 'L');
    expect(restored.mapPins.single.intensity, 95);
    expect(restored.mapPins.single.longitude, 121.0583);
    expect(restored.updatedAt, DateTime.utc(2026, 11, 25, 2));
  });

  test('accepts a ten-digit PSGC code in API updates', () {
    final update = LguUpdate(
      townCode: '0401005000',
      classes: 0,
      notice: '',
      floodAreas: const [],
      evacuationCenters: const [],
      updatedAt: DateTime.utc(2026, 11, 25),
    );

    final restored = LguUpdate.fromJson({
      ...update.toJson(),
      'townCode': update.townCode,
      'updatedAt': update.updatedAt.toIso8601String(),
    });

    expect(restored.townCode, '0401005000');
  });

  testWidgets('restores saved report entries and lets staff add a center', (
    tester,
  ) async {
    final update = LguUpdate(
      townCode: towns.first.code,
      classes: 1,
      notice: '',
      floodAreas: const [
        FloodAreaUpdate(name: 'Riverside report', level: 'H', status: 'F'),
      ],
      evacuationCenters: const [
        EvacuationCenterUpdate(
          name: 'School shelter',
          status: 'O',
          percentFull: 35,
        ),
      ],
      updatedAt: DateTime.utc(2026, 11, 25),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LguConsole(
              town: towns.first,
              api: LguApiService(),
              pinSnapshotSender: _StubPinSnapshotSender(),
              accessToken: null,
              existingUpdate: update,
              onMapPinsChanged: (_) {},
              onRequestPinLocation: (_) {},
              onCancelPinPlacement: (_) {},
              apiLoading: false,
              apiError: null,
              onRetry: () {},
              onPublished: (_) {},
              resetting: false,
              onReset: () async {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Flood-prone areas'));
    await tester.pumpAndSettle();
    expect(find.text('Riverside report'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'New flood area',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Added flood areas (1)'));
    await tester.tap(find.text('Added flood areas (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Riverside report'), findsOneWidget);

    await tester.tap(find.text('Evacuation centers'));
    await tester.pumpAndSettle();
    expect(find.text('School shelter'), findsNothing);
    await tester.ensureVisible(find.text('Added evacuation centers (1)'));
    await tester.tap(find.text('Added evacuation centers (1)'));
    await tester.pumpAndSettle();
    expect(find.text('School shelter'), findsOneWidget);
    await tester.tap(find.text('Added evacuation centers (1)'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Road status'));
    await tester.tap(find.text('Road status'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.text('Added roads (${towns.first.roads.length})'),
    );
    await tester.tap(find.text('Added roads (${towns.first.roads.length})'));
    await tester.pumpAndSettle();
    expect(find.text(towns.first.roads.first), findsOneWidget);

    final centerField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'New evacuation center',
    );
    await tester.ensureVisible(centerField);
    await tester.enterText(centerField, 'Temporary gym');
    final addButton = find.byTooltip('Add New evacuation center');
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(find.text('Temporary gym'), findsNothing);
    await tester.ensureVisible(find.text('Added evacuation centers (2)'));
    await tester.tap(find.text('Added evacuation centers (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Temporary gym'), findsOneWidget);
  });
}

class _StubPinSnapshotSender implements PinSnapshotSender {
  @override
  Future<void> sendPinSnapshot(
    String townCode,
    List<codec.MapPin> pins,
  ) async {}
}
