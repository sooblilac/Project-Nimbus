# Nimbus v3

White-and-blue redesign of the Nimbus demo: a map-first Android app with a typhoon indicator, plus the SMS server view, keyword SMS for any phone, and the LGU console from v2.

| Path | What it is |
|---|---|
| `index.html` + `nimbus-codec.js` | Web demo. Simulated: sample data, no SMS is sent. |
| `nimbus-codec.js` | The NB1 SMS format with no DOM, so it reads like the ports below. |
| `codec/nimbus_codec.py` | Python backend codec. `python3 codec/nimbus_codec.py` checks it against the test vectors. |
| `codec/nimbus_codec.dart` | Dart codec for the Flutter app (also copied into `flutter_app/lib/codec/`). |
| `codec/NimbusCodec.kt` | Kotlin codec, for an Android-phone gateway or native code outside Flutter. |
| `codec/test_vectors.json` | Encoded replies made by the JS codec. Every port must produce the same strings. |
| `design/tokens.json`, `design/logo.svg` | Colors, touch sizes and the logo. |
| `flutter_app/` | Flutter app: map, tab rail, bottom sheet, SMS through `another_telephony`, saved updates in SQLite. |

## Run the Flutter app

`flutter_app/` holds `lib/` and `pubspec.yaml` only, so generate the platform folders first:

```bash
cd flutter_app && flutter create --platforms=android . && flutter pub get
```

Then add these permissions to `android/app/src/main/AndroidManifest.xml`, set `gatewayNumber` in `lib/sms/sms_service.dart` to your gateway SIM, and run on a real phone with a SIM:

```xml
<uses-permission android:name="android.permission.SEND_SMS"/>
<uses-permission android:name="android.permission.RECEIVE_SMS"/>
<uses-permission android:name="android.permission.READ_SMS"/>
```

## Not verified

- The Dart, Kotlin and Flutter code was written without a Dart or Kotlin toolchain on this machine, so it hasn't been compiled. Run `flutter analyze` first.
- Only the Python port has been run against `test_vectors.json`.
- The `K` signature is a demo checksum. Use HMAC-SHA256 with a server key before any real pilot.
- The Flutter map shows flood overlays only; the web demo also draws evacuation sites and roads.
