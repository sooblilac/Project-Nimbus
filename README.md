# Project NIMBUS

Flood and storm updates for Philippine towns, even without mobile data. LGU staff publish
updates on a web dashboard, PAGASA bulletins are pulled in automatically, and residents get
everything in the NIMBUS app over the internet or **by plain SMS**.

## Download the app

**[⬇ Download NIMBUS for Android (APK)](https://github.com/sooblilac/Project-Nimbus/releases/latest/download/nimbus.apk)**

1. Open the link on an Android phone and download `nimbus.apk`.
2. Open the file. If Android asks, allow **Install unknown apps** for your browser or file manager.
3. Open NIMBUS → **Resident** → allow SMS permission → pick your town.

The app comes preloaded with the SMS gateway number (**0993 825 0146**) and the key that marks
replies as ✓ Verified, so there's nothing to set up.

### Using it without mobile data

- Tap **Get all updates by SMS** on the Overview. One text goes out; replies arrive in about 10–30
  seconds (storm, map pins, floods, evacuation, roads) and are saved for offline viewing.
- Each tab (Floods, Evac, Class status, Road status, Map pins) can also be requested on its own.
- Normal SMS rates apply. Limit: 5 requests per number every 10 minutes.

## For LGU staff

Dashboard: **https://nimbus-worker.gozocharlyz.workers.dev**

- Sign in with the account the NIMBUS administrator gave you. You only see your own towns.
- Open a town, edit classes, advisory, flood areas, evacuation centers, roads and map pins, then
  **Review → Publish**. Residents get it on their next update.
- **⋮ → Reset to all-clear** keeps your places but marks them safe.
  **⋮ → Clear all LGU data** removes everything for the town (PAGASA data is kept).

## How it works

```
Resident ──SMS "NB1 ASK A <town>"──▶ Gateway phone (SMS Gateway app)
                                          │ internet
                                          ▼
                               sms-gate.app cloud ──signed webhook──▶ Cloudflare Worker /sms
                                                                        │ reads town data (D1)
Resident ◀──signed NB1 replies── Gateway phone ◀── sms-gate.app ◀──────┘

LGU dashboard ──publish──▶ Cloudflare Worker (D1) ◀── PAGASA sync (GitHub Actions, every 30 min)
```

Everything except the gateway phone runs in the cloud, so no computer has to stay on.

| Piece | Where | Code |
|---|---|---|
| Resident app | Android | `nimbus-v3/flutter_app` |
| API, LGU dashboard, SMS relay | Cloudflare Worker + D1 | `nimbus-worker` |
| SMS message format (NB1) | shared codec | `nimbus-v3/codec`, `nimbus-v3/nimbus-codec.js` |
| PAGASA + rain sync | GitHub Actions (separate private repo) | `nimbus_sync.py`, `Storm/`, `pagasa_parser/` |

## Gateway phone setup (one time)

Any Android phone with a SIM that has load and an internet connection.

1. Install **[SMS Gateway for Android](https://sms-gate.app)** and allow its **SMS** and **Phone**
   permissions (if SMS is greyed out: App info → ⋮ → *Allow restricted settings*).
2. Turn **Cloud server ON**. Note the username and password it shows.
3. **Settings → Webhooks → Signing Key**: enter the value of `SMS_WEBHOOK_SIGNING_KEY`.
4. Turn off battery optimization for SMS Gateway and allow auto-launch / background running.
   Keep the phone charging and online.
5. If the gateway SIM number changes, rebuild the app with
   `--dart-define=NIMBUS_SMS_GATEWAY=<new number>` (or set it in the app's Settings).

## Developer setup

Secrets live in `.env` (see `.env.example`); it is git-ignored and must never be committed.

### Cloudflare Worker (`nimbus-worker`)

```bash
cd nimbus-worker
npm install
npx wrangler secret put SMS_WEBHOOK_SIGNING_KEY   # same as the gateway phone's Signing Key
npx wrangler secret put NIMBUS_SMS_SIGNING_KEY    # signs replies; the app is built with it
npx wrangler secret put SMS_USERNAME              # sms-gate.app cloud credentials
npx wrangler secret put SMS_PASSWORD
npx wrangler secret put ADMIN_SETUP_SECRET        # for creating LGU accounts
npx wrangler deploy
```

Point the gateway's webhook at the Worker once (replace the credentials):

```bash
curl -u USER:PASS -H 'Content-Type: application/json' \
  -d '{"id":"my-incoming-sms","url":"https://nimbus-worker.gozocharlyz.workers.dev/sms","event":"sms:received"}' \
  https://api.sms-gate.app/3rdparty/v1/webhooks
```

Create an LGU account (`townCodes` are PSGC codes, or `"*"` for all towns):

```bash
curl -X POST https://nimbus-worker.gozocharlyz.workers.dev/api/admin/users \
  -H "Authorization: Bearer $ADMIN_SETUP_SECRET" -H 'Content-Type: application/json' \
  -d '{"username":"aborlan-lgu","password":"<6+ chars>","townCodes":["1705301000"]}'
```

Local dev: `npx wrangler dev --local --port 8799 --var ADMIN_SETUP_SECRET:localtest`.

### Android app (`nimbus-v3/flutter_app`)

```bash
cd nimbus-v3/flutter_app
flutter test
flutter build apk --release \
  --dart-define=NIMBUS_SMS_SIGNING_KEY=<same as the Worker> \
  --dart-define=NIMBUS_SMS_GATEWAY=09938250146
```

Without `NIMBUS_SMS_SIGNING_KEY` the app still works but shows replies as "Not verified".
To publish a new APK: create a GitHub release and attach the file as `nimbus.apk`, so the
download link above keeps working.

### PAGASA sync

Runs `nimbus_sync.py` every 30 minutes on GitHub Actions in a separate private repo
(`charlyz23/nimbus-pagasa-sync`) with secrets `NIMBUS_LGU_USERNAME` / `NIMBUS_LGU_PASSWORD`
(an account with `townCodes: ["*"]`). Copy changes to `nimbus_sync.py`, `Storm/` or
`pagasa_parser/` into that repo. To run it by hand: `python3 nimbus_sync.py` with the same
variables set.

`SMS_SendAndRecieve/` is the older laptop-based relay (Python + cloudflared tunnel). It is
replaced by the Worker's `/sms` route and kept only for local testing.

## Security notes

- Webhooks are accepted only with a valid sms-gate signature and a fresh timestamp; retries are
  de-duplicated and replies are rate-limited per number and globally.
- Replies carry an HMAC signature (`K…`) checked by the app. The key is built into the APK, so it
  stops casual forgery, not a determined attacker who unpacks the app.
- Map data © OpenStreetMap contributors, tiles by OpenFreeMap / OpenMapTiles. Flood hazard
  layer © UP NOAH (ODbL).
