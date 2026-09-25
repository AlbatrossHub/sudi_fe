# sudi_fe

Flutter front end for Sudi — one codebase, two build flavors:

| Flavor | Audience | Base URL |
|---|---|---|
| `field` | pickup / delivery operators and job-work staff | `/api/field/v1` |
| `customer` | diamond customers sending a jangad | `/api/customer/v1` |

Both are offline-first against the Odoo 19 + FastAPI backend in the `sudi`
repository. The contract is frozen: see `sudi/docs/FLUTTER_INTEGRATION_BRIEF.md`,
`sudi/docs/openapi.field.json` and `sudi/docs/openapi.customer.json`.

## Design

`design/preview.html` — 24 screens across both flavors, neumorphic, with the API
call named under each. Open it in a browser; no build step.

`design/DESIGN.md` — the design system: tokens, component grammar, the screen
inventory mapped to endpoints, and the Flutter implementation notes.

`design/artboards/` — the same screens as canvas sources.

## Running it on a phone

The backend base URL is a compile-time constant with a default, so a quick
Cloudflare tunnel (which gets a **new hostname every restart**) is passed in
rather than committed:

### Where it points

The default is **production**, `https://manage.sdppl.com`, database `sudi`. A
build with no `--dart-define` is the one that ships; the tunnel hostnames that
used to be the default changed every restart and shipped stale. Whichever URL a
build carries is shown in the app under "Powered by Albatross", because "it will
not connect" is nearly always the server address.

> The API is not live on that host yet. `sudi_api` needs `odoo-addon-fastapi`
> and `PyJWT` in the server's environment, the `sudi` addons on its addons
> path, and the module installed — installing it creates the two
> `fastapi.endpoint` records that mint `/api/field/v1` and `/api/customer/v1`.
> Until then every call returns Odoo's 404 page and the app says
> "Request refused."

```bash
# live development, phone on USB with debugging on
flutter run --flavor field    -t lib/main_field.dart \
  --dart-define=SUDI_BASE_URL=https://<your-tunnel>.trycloudflare.com

flutter run --flavor customer -t lib/main_customer.dart \
  --dart-define=SUDI_BASE_URL=https://<your-tunnel>.trycloudflare.com

# installable builds
flutter build apk --release --split-per-abi --flavor field -t lib/main_field.dart
```

`--dart-define=SUDI_DB=sudi` overrides the database, which is appended as
`?db=` on every call because the server hosts several.

### When the phone has no internet

A quick tunnel is useless to a handset with no data. The phone can reach Odoo
on the dev machine straight down the USB cable instead — no internet, no
tunnel:

```bash
adb reverse tcp:8069 tcp:8069
flutter run --flavor field -t lib/main_field.dart \
  --dart-define=SUDI_BASE_URL=http://localhost:8069
```

`adb reverse` is cleared whenever the cable is unplugged or adb restarts, so
re-run it before each session. Cleartext HTTP is permitted to loopback
addresses only (`android/app/src/main/res/xml/network_security_config.xml`);
everything else stays HTTPS.

Check the server is reachable before blaming the app:

```bash
curl https://<your-tunnel>.trycloudflare.com/api/field/v1/health?db=sudi
```

Application ids are `com.sudi.field` and `com.sudi.customer`, so both flavors
install side by side on one handset — which is how the conflict cases get
tested.

## Build order

Per brief §11, stages A–C need no backend at all:

- **A.** The offline core against a fake backend — encrypted local DB, outbox
  with per-record serial flush, upload staging, the sync cursor protocol, the
  error taxonomy as a sealed class, clock offset. Highest-risk code; build and
  test it first.
- **B.** Flavors and shell — two entry points, two app ids, device uid in
  secure storage, local PIN gate.
- **C.** Field screens on cached data.
- **D.** Wire to the real server.
- **E.** Customer flavor.
- **F.** Push.

## What is built

**The offline core** (`lib/src/core/`) — this is the architecture, not a layer
added at the end:

- `db/` — SQLCipher-encrypted local store mirroring the sync payloads; whole
  documents kept as JSON, only list-query columns projected.
- `outbox/` — typed intents with a capture-time `Idempotency-Key` reused on
  every retry; flushed **serial per record, parallel across records**, so one
  record's conflict never blocks another's.
- `uploads/` — two-phase upload. An intent that names an image flushes the
  image first, takes the `reference`, patches it into the queued body, and only
  then sends the intent.
- `sync/` — cursor protocol with `upserts`/`gone`/`full_resync`, both paging
  modes, and `If-None-Match` (Dio's `validateStatus` widened, or a 304 throws).
- `clock/` — `server_time` drives an offset; every `occurred_at` is stamped
  from the corrected clock, and the 72-hour cliff is surfaced before it bites.
- `api/api_error.dart` — the error taxonomy as one type. `code` is the branch,
  `retryable` is the only thing that decides retry-versus-drop.

**Screens** — all 24 from `design/preview.html`, both flavors.

## Not built yet

- **Push** (stage F) — backend stage 7 does not exist yet, so there is no FCM
  token registration and no data-message-triggered pull.
- **Background flush on Android** (`workmanager`). The UX is designed for
  "flushes when the app is open", which is the honest promise on both platforms.
- **Biometric unlock.** The PIN gate is built; `local_auth` is not wired.
- **Tests.** The offline core is the highest-risk code in the project and it
  has no test suite yet. The brief's section 4.7 lists the six cases that
  matter, and they need a fake backend with an in-memory change log and a
  forced-409 switch.
