# EchoPin

Privacy-first group presence. See where your group is relative to you,
check in on people, and call for help, over Bluetooth or Wi-Fi. Sessions
run phone to phone with no server in the loop. Presence is relative, noisy,
and boundary-scoped: no coordinates are ever measured, stored, or
transmitted.

Organisations can add the optional [EchoPin server](docs/SERVER.md):
verified accounts, sealed emergency records of each session that only a
responder can open (for a stated, audited reason), reports and diagnostics
from every device, a central console, and encrypted backups.

## What it does

A small group creates or joins a temporary **session** with an invite code
or QR. Each phone shows the others on a pinwheel around "you", as distance
from Bluetooth signal strength, inside a boundary circle you drag to size.
When someone crosses the boundary you get an alert. Anyone can **check in**
on selected people or everyone, and anyone can raise an **SOS** that every
member receives, with delivery receipts and answers.

Everything is end-to-end encrypted and signed. Possession of the invite code
is what grants membership; nobody, including EchoPin, can read session
traffic without it. With a server configured, each phone also keeps a
sealed record of what it saw (see below).

## Features

- **Invites.** Codes `ECHO-XXXX-XXXX-XXXX-XXXX-CC` carry the session secret
  (~78 bits) plus a typo-catching checksum that works on any device. Share as
  QR, code or `echopin://join` link; join by scanning, pasting or typing.
  Every mistake gets a precise message ("Codes never contain 0, 1").
- **Pinwheel.** Live distances, drag-to-set boundary, privacy noise, SOS
  halos. Unconfirmed signals draw hollow; Wi-Fi-only peers are listed but
  not drawn, because no distance is known.
- **Peer tray.** A draggable bottom sheet of animated cards ("trays") that
  slide in and out as people appear and leave, with live distance, radio,
  verification badge and ping status. Long-press to select people.
- **Pings.** Check in with selected people or everyone; answers are
  *I'm OK*, *On my way* or *Need help*. **SOS** is press-and-hold, reaches
  people who join later, and resolves everywhere when you tap *I'm safe*.
  Pings retry until delivered and show per-person status.
- **Verification.** Every member has a per-session 12-digit safety code.
  Compare in person and mark the peer verified.
- **Status trays.** Animated cards explain what is wrong and fix it in one
  tap: Bluetooth off (*Turn on*), Bluetooth not allowed (*Allow* or
  *Settings*), not on Wi-Fi, nobody reachable, security warnings.
- **Two radios.** Bluetooth LE for offline use and distance; Wi-Fi or a
  hotspot for range. Both run at once; duplicates are dropped.
- **Alerts.** In-app banner, haptics (three pulses for SOS), and OS
  notifications on Android, iOS, macOS, Linux and Windows (in-app on web).
  An SOS always notifies, even with OS notifications switched off.
- **Sessions end by themselves** after 8 hours. Leaving sends a signed bye
  and wipes all keys. Recent sessions can be rejoined from the home screen.
- **Demo mode.** Four simulated people who run the *real* protocol:
  encryption, signatures, pings and answers.
- **Admin system** (PIN-protected): diagnostics, radio and alert settings,
  synthetic test peers, data tools, audit log.
- **Accounts and central console** (with a server): email-verified
  accounts, device-bound sign-in, two-step sign-in, *Report a problem*,
  and for responders and admins a console with an overview across every
  device, report triage, the session index with audited break-glass
  access, people, diagnostics, the audit chain and backups.

## Architecture

    lib/
      account/         server client, AccountProvider (tokens, device key),
                       Outbox (store-and-forward), SessionRecorder (sealed
                       emergency records)
      core/            EchoError: every failure as a typed, human sentence
      security/        codes → keys (HKDF), Ed25519 identity, envelope,
                       SecureMessenger (decrypt, verify, pin, replay, rate)
      session/         SessionEngine (membership, pings, receipts, retries),
                       DemoCrowd (simulated people running the engine)
      transport/       MessageTransport contract, Wi-Fi (Bonjour + TCP),
                       in-memory loopback
      services/        Bluetooth transport + native bridge, presence
                       (MeshService), noise, boundary monitor, notifications,
                       connectivity, history, settings, admin auth, bootstrap
      providers/       ChangeNotifiers: Session, Alert, Settings, Admin
      screens/         home, session, QR scanner, admin (gate + panel),
                       account (sign-in, account), report, console
      widgets/         pinwheel, animated tray list, peer / ping / status trays,
                       hold-to-send SOS
      ui/              theme and motion constants, formatting
    android/           Kotlin BLE plugin (advertise, scan, GATT inbox/client)
    ios/               Swift BLE plugin (same protocol)
    packages/echopin_protocol/  sealed boxes, device proofs, shared enums
    server/            central server (Dart + PostgreSQL), see docs/SERVER.md
    docs/PROTOCOL.md   the wire protocol, normative
    docs/CODE_MAP.md   guided tour: what every part of the code does
    docs/SECURITY_REVIEW.md  auth/verification threat review and fixes

Native code only moves opaque bytes. All cryptography is in Dart, so it is
identical on every platform and tested on the desktop.

The session pipeline:

    radios ──frames──▶ SecureMessenger ──▶ SessionEngine ──members/pings──┐
    BLE ──sightings──▶ MeshService ───────────────────────────────────────┤
                                                                          ▼
                    SessionProvider: merge → privacy noise → boundary crossings
                                     → Session.peers, trays, alerts → UI

Six `InheritedNotifier` scopes (`SettingsScope`, `AlertScope`,
`SessionScope`, `AdminScope`, `AccountScope`, `OutboxScope`) expose
providers without an external state-management dependency.

## Privacy and security model

- **Relative only.** No field anywhere holds a coordinate. Distance comes
  from Bluetooth signal strength measured on the receiving phone; nothing
  location-like is sent.
- **Noisy by default.** Distances are jittered by up to ±sigma (default 7 m)
  with an offset fixed per peer per minute, before alerts or the UI see them.
- **Encrypted and signed.** XChaCha20-Poly1305 with a key derived from the
  code; Ed25519 signatures with a fresh key per device per session; sender
  ids derived from keys and pinned on first use; 64-message replay window;
  ±2 min clock window; per-sender rate limits; 20-member cap.
- **Untrusted input.** Names and notes from the network are stripped of
  control and bidi-override characters and length-capped. Unconfirmed BLE
  sightings never trigger alerts and cannot be pinged.
- **Secrets at rest.** Invite codes in the recent-sessions list and the admin
  PIN hash live in the OS keystore (Keychain / EncryptedSharedPreferences),
  falling back to app preferences only where no keystore exists. Peers,
  distances and pings are never persisted.
- **With a server.** Accounts use Argon2id passwords, verified email and
  optional TOTP; each install signs in with its own Ed25519 device key (no
  IMEI or hardware ids), and every token refresh must be signed by it.
  Session records are sealed on the phone to the server's escrow key and
  can only be opened by a responder who gives a reason, which goes into a
  hash-chained audit log. Records never contain coordinates. Details in
  `docs/SERVER.md`.
- **Not provided:** forward secrecy within a session, hiding that a session
  exists nearby (its public id is advertised), or protection from a member
  who leaks the code. See `docs/PROTOCOL.md` §8 and `docs/THREAT_MODEL.md`.

## Admin system

Reached from the shield icon on the home screen or the session menu. Fully
offline.

- **Access.** The first visit creates a 4–12 digit PIN; only a salted
  PBKDF2-HMAC-SHA256 hash is stored. Five wrong PINs lock the gate for 60 s,
  surviving restarts. The panel auto-locks after 5 minutes idle.
- **Enforcement.** `AdminProvider` checks the unlocked state on every
  privileged call, so the gate holds even if a screen is reached some other
  way.
- **Diagnostics.** Platform, storage, notifications, radios with live
  health, session id, your peer id and safety code, members, messages sent /
  accepted / rejected, rejection reasons. Never the invite code.
- **Settings.** Default boundary, privacy noise, alerts, OS notifications,
  haptics, Bluetooth and Wi-Fi radios, force simulation.
- **Synthetic peers.** Inject, move or remove test peers; they flow through
  noise, crossing detection and alerts like real ones.
- **Data & security.** Clear history, reset settings, change or remove PIN.
- **Audit log.** In memory, this run only.

## Accounts and central console (optional)

Build with `--dart-define=ECHOPIN_SERVER_URL=https://your-server` to turn
them on; without it the app is fully local, as above.

- **Sign-in.** Live sessions need an account (the demo never does). Create
  one in the app: name, email, password (10+ characters), then the 6-digit
  code from the email. Sign-in persists offline; only the server can sign
  you out, and the app says why.
- **Account screen.** Two-step sign-in with any authenticator app (QR
  code), change password, see and remove your devices, *Report a problem*,
  follow your reports, and see what is still waiting to upload.
- **Emergency records.** Live sessions are recorded on the phone and
  uploaded sealed: a checkpoint within seconds of an SOS, then the final
  record. Everything waits in an outbox when there is no signal.
- **Console** (responders and admins): overview with 14-day trends,
  reports sorted critical-first, session index with *Open* (reason
  required, permanently logged), and for admins people, diagnostics, the
  audit log with a chain check, and backups.

Running the server: free hosted setup in `docs/DEPLOY_HOSTED.md`
(Render + Supabase + Brevo), everything else in `docs/SERVER.md`.

## Backend fallbacks

Every platform probe has a timeout and a working substitute, so the app
always launches.

| Capability | Primary | Fallback |
| --- | --- | --- |
| Secret storage | OS keystore | App preferences |
| OS notifications | `flutter_local_notifications` | In-app banner only |
| Bluetooth | Native plugin (Android, iOS) | Session runs on Wi-Fi; a tray explains |
| Wi-Fi transport | Bonjour + TCP | Session runs on Bluetooth; a tray explains |

Real sessions never fall back to simulated people. Permission prompts wait
until after the first frame.

## Platform support

| Platform | Bluetooth | Wi-Fi | QR scan | Notes |
| --- | --- | --- | --- | --- |
| Android | yes | yes | yes | Release APK built and signed on Linux |
| iOS | yes | yes | yes | Foreground BLE; needs a macOS host to build |
| macOS | — | yes | yes | macOS host |
| Linux | — | yes | paste | Needs avahi for Bonjour |
| Windows | — | yes | paste | Windows host |
| Web | — | — | yes | Demo only: browsers cannot use these radios |

## Development

    flutter pub get
    flutter analyze                     # must be clean
    flutter test                        # unit + widget tests
    flutter test integration_test -d linux   # real Bonjour + TCP
    flutter run                         # or -d linux / -d chrome
    (cd server && ./tool/test.sh)       # server: throwaway PostgreSQL + all tests

`--dart-define=ECHOPIN_FORCE_SIM=true` skips the Bluetooth probe.

## Building

Android. Release signing reads `android/key.properties`; its `storeFile` is
relative to `android/` (for example `keystore/release.jks`). Without a usable
keystore the release build falls back to the debug key, so fresh clones and
CI still build:

    flutter build apk --release

Others:

    flutter build linux      # clang cmake ninja-build libgtk-3-dev libsecret-1-dev
    flutter build web
    flutter build ios --no-codesign   # macOS host
    flutter build macos               # macOS host
    flutter build windows             # Windows host

Requirements: Flutter 3.38 or newer (CI uses 3.44), JDK 17 or newer, and
about 3 GB of free RAM for Gradle (`android/gradle.properties` sets
`-Xmx2G`).

## Testing

    test/
      security/    codes, key derivation, identity, envelope tampering,
                   wrong keys, impersonation, replay, clock skew, flooding,
                   member cap
      session/     whole sessions in memory: discovery, targeted and
                   broadcast pings, lossy links, partitions, late joiners,
                   reply retries, sanitisation, wipe on exit
      providers/   two complete apps over a shared radio: join, pings, SOS
                   and "I'm safe", verification, trays, demo, history;
                   admin lock enforcement and diagnostics
      services/    BLE transport recovery (off → on, permissions), presence,
                   PBKDF2 vectors, noise, notifications, history
      widgets/     end-to-end UI: home, demo with answers, hold-to-send
                   SOS, inline code errors, wide layout, admin flows
    integration_test/  real Bonjour discovery and TCP between two engines

## Status

Verified on this repository's Linux host:

- Analyzer clean; unit, widget and Linux integration tests pass.
- Android release APK builds with the Kotlin GATT plugin compiled in.
- Linux and web release builds; the web demo renders and runs.

Not yet verified (needs hardware or another host OS):

- **Bluetooth between real phones.** The GATT code compiles for Android and
  follows CoreBluetooth's rules on iOS, but has not run on devices. Test two
  phones in one session, then an Android with an iPhone.
- **iOS and macOS builds** (CI builds them on macOS runners).
- **Background operation.** Bluetooth discovery runs while the app is open.
  iOS does not advertise local names in the background, and Android may
  pause scans with the screen off.

## CI

Workflows in `.github/workflows/`, pinned to Flutter 3.44.0:

| File | Runs |
| --- | --- |
| `build.yml` | Release builds for Android, web, Linux, iOS (no codesign), macOS, Windows |
| `lint.yml` | `flutter analyze` and a `dart format` check |
| `test.yml` | Unit and widget tests with coverage, plus the Linux integration test |
| `ci.yml` | Summary |
| `dependency-check.yml` | Manual `pub outdated` |
