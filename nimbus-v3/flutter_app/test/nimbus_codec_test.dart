import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus/codec/nimbus_codec.dart';

void main() {
  test('round-trips an SMS map-pin snapshot, including an empty snapshot', () {
    final message = encodePins('0412', const [
      MapPin(
        category: 'flood',
        label: 'Market crossing',
        latitude: 13.75634,
        longitude: 121.05831,
        status: 'F',
        intensity: 95,
      ),
      MapPin(
        category: 'evacuation',
        label: 'Central School',
        latitude: 13.75,
        longitude: 121.05,
        status: 'O',
        intensity: 45,
      ),
    ], '0800');

    final reply = decode(message);
    expect(reply, isNotNull);
    expect(reply!.valid, isTrue);
    expect(reply.type, 'P');
    expect(reply.townCode, '0412');
    expect(reply.pins, hasLength(2));
    expect(reply.pins.first.label, 'Market crossing');
    expect(reply.pins.first.latitude, 13.75634);
    expect(reply.pins.first.longitude, 121.05831);
    expect(reply.pins.last.category, 'evacuation');

    final emptyReply = decode(encodePins('0412', const [], '0801'));
    expect(emptyReply, isNotNull);
    expect(emptyReply!.valid, isTrue);
    expect(emptyReply.pins, isEmpty);
  });

  test('does not accept pin snapshots with invalid checksum or status', () {
    final valid = encodePins('0412', const [
      MapPin(
        category: 'road',
        label: 'Rizal Street',
        latitude: 13.75,
        longitude: 121.05,
        status: 'X',
        intensity: 100,
      ),
    ], '0800');
    expect(decode(valid)?.valid, isTrue);
    expect(
      decode(valid.replaceFirst(RegExp(r'K[0-9A-F]{8}$'), 'K00000000'))?.valid,
      isFalse,
    );

    final invalid = encode('P', '0412', const [
      'F|X|100|1375000|12105000|Rizal_Street',
    ], '0800');
    expect(decode(invalid), isNull);
  });
}
