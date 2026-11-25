# nmbus v3

White-and-blue NIMBUS app: a role-selection landing page, an interactive offline Philippines map, resident SMS status requests and a separate LGU dashboard.

| Path | What it is |
|---|---|
| `index.html` + `nimbus-codec.js` | Web demo. Simulated: sample data, no SMS is sent. |
| `nimbus-codec.js` | The NB1 SMS format, including map-pin snapshots, with no DOM. |
| `codec/nimbus_codec.py` | Python backend codec. `python3 codec/nimbus_codec.py` checks it against the test vectors. |
| `codec/nimbus_codec.dart` | Dart codec for the Flutter app (also copied into `flutter_app/lib/codec/`). |
| `codec/NimbusCodec.kt` | Kotlin codec, for an Android-phone gateway or native code outside Flutter. |
| `codec/test_vectors.json` | Encoded replies made by the JS codec. Every port must produce the same strings. |
| `api/` | Small Node.js API for LGUs to publish town status and residents to read the latest update. |
| `design/tokens.json`, `design/logo.svg` | Colors, touch sizes and the logo. |
| `flutter_app/` | Flutter app: offline city/municipality search, resident status view, LGU update console, SMS through `another_telephony`, saved updates in SQLite. |

## Run the LGU API

The API uses only Node.js built-ins and stores published updates in
`api/data/updates.json` (override with `NIMBUS_DATA_FILE`). Start a local demo server with:

```bash
cd nimbus-v3
node api/server.js
```

In development, the demo login is **`demo` / `nimbusdemo26`** and can publish to
all towns. The demo account is disabled when `NODE_ENV=production`. For real accounts,
configure `NIMBUS_LGU_USERS` as server-side environment configuration; each account has
a password of at least 12 characters and an assigned list of town codes:

```bash
NIMBUS_LGU_USERS='{"batangas-staff":{"password":"use-a-long-private-password","townCodes":["0401005000"]}}' node api/server.js
```

Use `"townCodes":["*"]` only for an all-town administrator. Do not put real passwords in
the app or commit them. Login sessions expire after eight hours and are invalidated when
the API restarts; the Flutter app silently signs back in using credentials kept in Android
secure storage. Signing out removes the saved credentials. Residents can read
`GET /api/towns/{townCode}/updates`; authenticated
LGU staff publish a complete snapshot to the same path. `GET /health` checks server readiness.
The older per-town `LGU_TOKENS` bearer-token configuration remains supported.

The API listens on port `8080` (override with `PORT`). Preserve the updates file and use
persistent storage when hosting the service. It accepts either four-digit legacy IDs or
ten-digit PSGC IDs. Android emulators use `http://10.0.2.2:8080/api`. For a phone connected
over USB, run `adb reverse tcp:8080 tcp:8080` and build/run with
`--dart-define=NIMBUS_API_URL=http://127.0.0.1:8080/api`.
The debug build permits local HTTP; production must use HTTPS.

Residents and LGU staff have separate screens and use the same offline location picker.
The LGU dashboard requires sign-in, filters locations to the account's assigned towns, and
starts each report from the town's last saved data. staff can add flood areas, evacuation
centers and roads, set road conditions, and write custom advisories. Residents see these
updates together in Overview and separately in the matching status panel. The LGU console can
reset the selected town's published report and locally saved resident SMS replies after confirmation;
SMS copies on other residents' devices are not deleted. If the existing report cannot load, publishing is disabled
to avoid replacing saved statuses with defaults.
LGU staff can place flood, evacuation-center, and road pins on the map, set their status and
intensity, then publish them with the town report. Residents can tap published pins for details.
Pins are shared through the authenticated town-update API and as an NB1 `P` SMS snapshot.
The compact `NB1~P~...~K` snapshot framing survives multipart SMS reassembly; coordinates keep
five decimal places and residents can tap each returned pin for its status bubble. Residents
request snapshots from the map-pins panel with `ASK P`.

To run the SIM phone as the pin relay, set its trusted LGU sender number in Settings, then choose
**Open SMS gateway on this phone**. On the LGU phone, set the SMS receiver number to the relay
phone's SIM number; residents set that same number as their receiver. The gateway stores accepted
pin snapshots locally and replies to resident pin requests for the matching town. Keep the gateway
phone powered on with its SIM active, start gateway mode once, and do not force-stop NIMBUS.
The gateway currently handles map-pin snapshots only; it is not a general SMS relay for storm,
flood, evacuation, or road-status requests.


The Flutter app bundles a searchable offline catalog of 1,634 Philippine cities and
municipalities. It includes PSGC IDs, province/region labels, and latitude/longitude; selected
coordinates are shown in the location picker and marked on the map. The original four sample
towns retain their legacy SMS IDs. Other locations use their PSGC ID for API and SMS requests,
so confirm that the SMS gateway supports ten-digit PSGC IDs before deployment.

The interactive map uses OpenFreeMap/OpenMapTiles vector tiles based on OpenStreetMap. Users
can download a Philippines overview and optional detail packs for a selected town for offline
pan/zoom; each user-started pack is limited to 3,000 tiles and 45 MB. Map attribution is shown
in the app. The bundled Philippine outline and location catalog remain available offline.
Catalog names/codes are based on PSGC data; coordinates were matched using GeoNames and GeoBoundaries
ADM3 data, with centroid fallbacks for some locations. The map outline is from Natural Earth
10m data and includes a GeoBoundaries municipality outline for Kalayaan. The current catalog
uses boundary-centroid fallbacks for 172 locations where no matched place point fell inside its
municipal boundary. See
[PSGC](https://psgc.gitlab.io/api/), [GeoNames](https://www.geonames.org/),
[GeoBoundaries](https://www.geoboundaries.org/) and
[Natural Earth](https://www.naturalearthdata.com/) for source details and licensing.
Location/map data is not a hazard-data source: LGUs must publish verified flood, suspension and
evacuation-center statuses. Check all coordinates, boundaries and source-license requirements
before operational use.

Run the API tests with `node --test api/server.test.js`. This is a lightweight demo backend:
host it behind HTTPS, disable the demo account, configure private server-side credentials,
and use a transactional database before operational deployment.

## Run the Flutter app

Run the app on a connected Android phone:

```bash
cd flutter_app
flutter pub get
flutter devices
adb reverse tcp:8080 tcp:8080
flutter run -d <device-id> --dart-define=NIMBUS_API_URL=http://127.0.0.1:8080/api
```

For an Android emulator, omit `adb reverse` and use
`--dart-define=NIMBUS_API_URL=http://10.0.2.2:8080/api`.

The app opens on the NIMBUS landing page, then opens a resident, LGU, or SMS gateway screen.
The app requests SMS send/receive permission when opening a resident or gateway screen.
`READ_SMS` is not requested; the app handles incoming messages delivered to its SMS receiver.
Configure the relay SIM number at build time with
`--dart-define=NIMBUS_SMS_GATEWAY=+63...` before sending requests. Until configured, requests
are blocked rather than sent to a placeholder number. The Settings panel can also save a
device-local receiver number, trusted LGU sender number, and dark-mode preference. After a
storm-update SMS request remains unanswered for 20 seconds, the app can show current Open-Meteo
weather for the selected town; this is general weather information, not an official warning.

For local Android-emulator testing over plain HTTP, temporarily set
`android:usesCleartextTraffic="true"` on the `<application>` element. Do not ship that setting;
use HTTPS for a deployed API.

## Not verified

- The in-app gateway handles only map-pin snapshots (`P`) and `ASK P`; other update types still need a gateway handler.
- Verify multipart SMS delivery with the target carriers and SIM devices before deployment.
- The `K` signature is a demo checksum, not authentication. The gateway also checks the configured LGU sender number; use HMAC-SHA256 before any real pilot.
- Open-Meteo weather is a general forecast/current-conditions fallback and is not an official warning.
