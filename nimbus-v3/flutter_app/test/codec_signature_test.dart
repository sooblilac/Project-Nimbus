import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus/codec/nimbus_codec.dart';

void main() {
  final vectors =
      jsonDecode(File('../codec/test_vectors.json').readAsStringSync()) as List;

  tearDown(() => setSigningKey(devSigningKey));

  test('produces and accepts the shared test vectors (same key as Python)', () {
    setSigningKey(testVectorKey);
    for (final v in vectors.cast<Map<String, dynamic>>()) {
      if (v.containsKey('tampered')) {
        expect(decode(v['tampered'] as String)!.valid, isFalse);
        continue;
      }
      final sms = v['type'] == 'P'
          ? encodePins(
              v['town'] as String,
              [
                for (final p in (v['pins'] as List).cast<Map<String, dynamic>>())
                  MapPin(
                    category: p['category'] as String,
                    label: p['label'] as String,
                    latitude: (p['latitude'] as num).toDouble(),
                    longitude: (p['longitude'] as num).toDouble(),
                    status: p['status'] as String,
                    intensity: p['intensity'] as int,
                  ),
              ],
              v['time'] as String,
            )
          : encode(
              v['type'] as String,
              v['town'] as String,
              (v['fields'] as List).cast<String>(),
              v['time'] as String,
              v['notice'] as String,
            );
      expect(sms, v['sms']);
      expect(decode(sms)!.valid, isTrue);
    }
  });

  test('a reply signed with another key is not verified', () {
    setSigningKey('relay-real-key');
    final sms = encode('Q', '0412', const ['W2', 'R3'], '0800', '');
    setSigningKey(devSigningKey);
    expect(decode(sms)!.valid, isFalse);
  });

  test('the old 4-digit checksum format is not verified', () {
    expect(decode('NB1 Q 0412 W2 R3 G75 E1O C1 T0800 KE285')!.valid, isFalse);
  });
}
