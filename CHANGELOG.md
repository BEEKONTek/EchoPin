# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.5.0] — 2026-11-12

### Added
- **Input validation everywhere.** Every text field is capped in the app at
  the exact limit the server enforces (one shared `ProtocolLimits`), with
  instant local checks for email shape, name, password and codes before a
  request goes out. On the server, ids in URLs are checked before any
  query (404, never a database error), paging is clamped, search text is
  length-capped, and a value PostgreSQL refuses becomes a 400 instead of a
  500. The CLI reports a bad `--email` as a usage error.
- **System test in one command**: `server/tool/live_check.sh` starts a
  throwaway database and server and runs 31 end-to-end checks over HTTP.
- `docs/IMPLEMENTATION.md`: coding, testing, system test cases with
  results, and installation, with a PDF.
- GitHub Pages workflow publishing the web demo.

### Changed
- CI: Lint resolves the nested packages before analysing (it reported 975
  false errors), test steps use the `github` reporter so failures are
  readable as annotations, the server job pins `pg_dump`/`pg_restore` to
  the service's PostgreSQL major, integration tests run one file per step,
  and the unverified Windows build no longer fails the workflow.
- Widget tests wait for the fake server to be idle instead of a fixed
  delay, so slow CI runners don't fail them.
- Docs: stale June-era `API.md`/`ROADMAP.md` removed; `ARCHITECTURE.md`,
  `SETUP.md` and the handoff rewritten for the current system; README
  redesigned.
- Server version 1.1.0.


### Added
- **Account PIN.** The signed-in account is now behind a local PIN, like
  the admin panel (same PBKDF2 PIN code, separate storage). Chosen right
  after sign-in; guards Account, reports and the console, never sessions,
  check-ins or SOS. Padlock button to lock, auto-lock after 5 minutes idle
  (wall clock, so background time counts), 5 wrong PINs lock it for 60 s,
  and the 3rd lockout in a row signs the account out. *Forgot your PIN?*
  signs out; signing out or in always wipes the PIN. Locking keeps the
  screen underneath alive, so a half-written report survives. Change PIN
  under Account → Security.

### Changed
- **Pinwheel range is now 100 m** (was 500 m), with rings every 25 m. The
  boundary goes from 10 to 100 m in 5 m steps, default 50 m; a default saved
  on the old scale (over 100 m) resets to 50 m. Demo people start closer.
  Privacy noise maximum is now 20 m.

### Fixed
- **Pinwheel no longer shows a made-up direction.** Bluetooth measures
  distance only, but people were drawn at an angle derived from their id,
  with a direction line and an "N" marker, so it looked like a compass
  reading. Bluetooth people are now spaced evenly at their distance, with
  no line and no "N", under the caption *Distance only · direction
  unknown*. New `PeerPresence.hasBearing` marks which angles are real.

## [0.4.0] — 2026-11-08

### Added
- **EchoPin server** (`server/`, `docs/SERVER.md`): Dart + PostgreSQL,
  Docker Compose, operator CLI. Optional: the app stays fully local unless
  built with `--dart-define=ECHOPIN_SERVER_URL=…`.
- **Accounts**: email verification, Argon2id passwords, two-step sign-in
  (TOTP, QR setup), password reset, lockout and rate limits. Each install
  signs in with its own Ed25519 device key instead of any hardware id;
  token refresh is signed by it, and a replayed refresh token signs the
  device out (theft detection).
- **Sealed emergency records**: every live session is recorded on the
  phone (joins, pings, SOS, answers, boundary crossings, security alarms,
  last known distances; never coordinates), sealed to the server's escrow
  key, and uploaded through a store-and-forward outbox. Checkpoints go up
  seconds after an SOS. Responders open a record only by giving a reason,
  recorded in a hash-chained, append-only audit log.
- **Report a problem** with safety reports that can be marked urgent,
  optional diagnostics and a linked session; follow status under Account.
- **Central console** for responders and admins: cross-device overview
  with 14-day trends, report triage, session index and break-glass, people
  (roles, disable, unlock, sign out everywhere, devices), diagnostics,
  audit chain check, backups.
- **Encrypted backups**: daily `pg_dump`, AES-256-GCM framed format with
  truncation detection, retention, `verify-backup` and CLI-only `restore`.
- `packages/echopin_protocol`: wire formats shared by app and server.
- CI job running protocol and server tests against PostgreSQL.
- **Free hosted deployment** (`render.yaml`, `docs/DEPLOY_HOSTED.md`):
  Render web service + Supabase Postgres and Storage + Brevo email, with a
  keep-awake workflow. Keys travel as one `ECHOPIN_KEYS` secret; the server
  refuses to start rather than generate keys on a throwaway disk.
  Backups go to a private Supabase bucket in parts under the 50 MB limit,
  dump only EchoPin's schema, and never drop the host's own schemas on
  restore. Email codes via Brevo or Resend HTTP APIs (hosted platforms
  block SMTP). TLS is required automatically for remote databases; one
  backup at a time across instances; the app waits out a sleeping server.

### Security
- Reviewed every authentication and verification path; findings and
  fixes are in `docs/SECURITY_REVIEW.md`.
- **Client IPs can't be spoofed.** The server took the leftmost
  `X-Forwarded-For` entry, which the client writes, so per-IP rate limits
  could be dodged and audit-log addresses forged. It now uses
  `CLIENT_IP_HEADER` (Render: `true-client-ip`) or the entry
  `TRUSTED_PROXY_HOPS` from the right.
- **No account pre-hijacking.** Confirming an email now needs the sign-up
  password, so re-registering someone's pending address can't get the
  attacker's password activated by the victim's code.
- **Lockout can't be raced.** Failed sign-ins are counted atomically.
- **Code guessing capped** at 10 codes per account per day, in the
  database (5 guesses each).
- **Audit chain is keyed** (HMAC with a key from `ECHOPIN_KEYS`), so full
  database access is no longer enough to rewrite it undetected. Each
  backup logs the chain tip. `create-admin` and `audit-verify` now need
  the keys.
- **Two-step:** turning it on needs the password; a code can't be used by
  two racing sign-ins; admins can reset it for a lost phone.
- **Stricter email addresses** (no commas, brackets or quotes).
- **App:** release builds refuse plain-`http` servers; device proofs use
  the server's clock (from the `Date` header), so a wrong phone clock no
  longer blocks sign-in, and a refused proof no longer signs you out.
- Fixed: signing in to an unconfirmed account now really sends a new code
  and lets you confirm it (the pending email was cleared first).
- **Custodian key (second seal).** With `CUSTODIAN_PUBLIC_KEYS` set
  (`echopin_admin init-custodian`), phones seal records twice and the
  server alone can no longer read them; responders open the inner seal in
  the console with a key that never leaves their device. Phones never
  downgrade, and the key can be built into the app
  (`ECHOPIN_CUSTODIAN_KEY`).
- **Lockout can't be used against the owner.** Locks are per email (with
  or without an account) and skip the account's own registered devices.
- **Rate limits in PostgreSQL**, shared and restart-proof.
- **No account enumeration:** uniform answers and timing, background
  mail, one generic code error, 8-digit codes.
- **Breached passwords refused** (Have I Been Pwned, k-anonymity).
- **Staff must use two-step** before the console answers them.
- **Every admin is emailed** when a record is opened; responders no longer
  see email addresses; person lookups and session views are audited.
- **Session tag** flags uploads from people who weren't in the session.
- **Retention:** old records, diagnostics and closed reports are deleted
  daily (configurable).
- **Audit anchors** stored with backups catch rows cut from the end.
- Devices without a keystore get 7-day sessions and a warning; unsafe
  `ECHOPIN_DEV` / `CORS_ORIGINS=*` settings are refused.

### Fixed
- **Found by testing the real app against a live server:**
  - The two-step setup dialog threw a layout error on every platform (the
    QR code inside an AlertDialog had no fixed size).
  - Opening a sealed record in the console crashed debug builds right after
    the (already audited) opening, so the responder never saw the record.
  - The console counted one SOS once per phone that saw it ("3 SOS" for one
    event) and the SOS chart disagreed with its tile.
  - With one real member and one outsider, the session-tag check guessed and
    could brand the real member's record as "not proven". Votes now count
    people, not uploads, and ties are shown as unknown.
- **SOS stays up for responders.** Answering *On my way* used to close the
  alert while the sender still needed help, and the sender's row kept
  showing an older *OK*. The alert now stays (showing "You're on your
  way") until the sender is safe, and their row shows **SOS**.
- **"I'm safe" is confirmed.** It was sent twice with no receipt, so a
  busy or briefly out-of-range phone could miss it and keep a stale SOS.
  It is now retried until each recipient confirms (`safe` receipt).
- **Linux: no false "Not on Wi-Fi".** Wi-Fi managed by iwd,
  systemd-networkd or ConnMan is invisible to NetworkManager; the app now
  also checks network interfaces (rechecked every 15 s).
- **Window title** reads "EchoPin" on Linux and Windows.

## [0.3.0] — 2026-11-06

Protocol v2. Breaking: v1 invite codes no longer work; old entries are
hidden from Recent sessions.

### Added
- **Encrypted, signed messaging** (`docs/PROTOCOL.md`): session key from the
  invite code via HKDF-SHA256, XChaCha20-Poly1305 envelopes, per-session
  Ed25519 identities, key-derived and pinned peer ids, replay window, clock
  skew check, per-sender rate limits, 20-member cap.
- **Pings**: check in with selected people or everyone; answers *I'm OK*,
  *On my way*, *Need help*; delivery receipts and retries; press-and-hold
  **SOS** that reaches late joiners and resolves everywhere on *I'm safe*.
- **Wi-Fi / hotspot transport** (Bonjour + TCP) alongside Bluetooth.
- **Bluetooth GATT messaging** in the Android and iOS plugins, adapter-state
  events, and an in-app request to turn Bluetooth on.
- **QR scanning** for invites, paste from clipboard, `echopin://join` links.
- **Safety codes** for in-person verification.
- **Status trays** for Bluetooth off / denied / blocked, no Wi-Fi, nobody
  reachable, and security warnings, each with a one-tap fix where possible.
- **Animated tray UI**: draggable people sheet with cards that slide in and
  out, animated recent sessions, rounded alert trays, SOS halo on the
  pinwheel, side panel on wide screens.
- Display name setting; Bluetooth and Wi-Fi radio switches in admin.
- Integration test over real Bonjour and TCP.

### Changed
- Invite codes are `ECHO-XXXX-XXXX-XXXX-XXXX-CC` with a keyless checksum, so
  any device can validate them (v1 checksums only worked on the device that
  made the code).
- Recent sessions, which contain invite codes, are stored in the OS keystore.
- Demo mode runs the real protocol with simulated people; real sessions never
  show simulated people.
- Android Gradle Plugin 8.9.1, Gradle 8.11.1, Kotlin 2.2.20; Flutter 3.38+.

### Fixed
- Teardown no longer awaits broadcast-stream cancellation (hung under
  FakeAsync).
- Wi-Fi socket write errors are handled instead of escaping as unhandled
  errors.

## [0.2.0] — 2026-11-05

### Added
- PIN-protected admin system, settings, privacy noise, drag-to-set pinwheel,
  QR display, session history. Build fixes for every platform.

## [0.1.0] — 2026-06-15 (MVP Alpha)

### Added
- **Core Session Management**
  - Create ephemeral peer-to-peer sessions with 6-character session IDs
  - Join sessions via QR code scanning
  - Auto-expiring sessions (default 8 hours)
  - Full data wipe on session exit

- **Location Engine**
  - GPS + compass heading for bearing/distance calculation
  - Planar Laplace noise obfuscation (ε=0.5)
  - Haversine distance computation
  - BLE RSSI fallback distance estimation (stub)
  - Dead-reckoning position estimation via IMU (stub)

- **Mesh Networking**
  - BLE peer discovery via session UUID advertisement
  - Noise XX handshake (stub; no actual encryption yet)
  - Presence update broadcasting (encrypted payload stub)
  - Rate limiting (2 updates/second per peer)
  - Replay attack protection (nonce + timestamp validation)
  - Session size cap (max 20 peers)
  - Multi-hop message relay (stub via libp2p)

- **Radial Pinwheel UI**
  - Circular pinwheel with peer arms pointing in direction
  - Distance encoded as dot position on arm
  - Dashed boundary ring (configurable radius, 50m–500m)
  - Breach detection (red banner + haptic feedback)
  - Cardinal direction labels (N/S/E/W)
  - Concentric reference rings (25%, 50%, 75%, 100%)
  - Emoji + distance labels per peer
  - Dark/light mode support

- **Peer Management**
  - Display name + emoji assignment per peer
  - Real-time position updates
  - Stale data detection (>10s without update)
  - Boundary status tracking

- **Hardware Haptics**
  - Heavy impact feedback on boundary breach
  - Configurable vibration patterns

- **Testing**
  - Unit tests for LocationEngine (noise generation, bearing/distance)
  - Unit tests for MeshService (message validation, rate limiting)
  - Widget tests for PinwheelPainter
  - Simulated peers for development (no real BLE required for demo)

### Changed
- None (initial release)

### Fixed
- None (initial release)

### Deprecated
- None (initial release)

### Removed
- None (initial release)

### Security
- Implemented planar Laplace noise for location obfuscation
- Ephemeral keys (no persistent credentials)
- Session data auto-wipe on exit
- No absolute GPS coordinates broadcast
- Rate limiting to prevent DoS

### Known Issues
- BLE discovery uses stubs (real flutter_blue_plus integration planned for Beta)
- Noise XX encryption is a pass-through stub (real implementation planned for Beta)
- No actual Wi-Fi Direct support (stub only)
- UWB ranging not implemented (planned for Beta)
- IMU dead-reckoning is linear projection only (full integration planned for Beta)
- QR code scan not fully implemented (placeholder stub)

---

## [0.2.0] — TBD (MVP Beta)

### Planned
- **Networking Hardening**
  - Real Noise XX implementation (using dart_libp2p)
  - Actual BLE encryption payload transmission
  - Wi-Fi Direct peer-to-peer upgrade
  - Multi-hop relay validation

- **Location Fusion**
  - Full IMU integration (accelerometer + gyroscope)
  - Step detection for dead-reckoning
  - Gyroscope heading fusion
  - Error drift correction on GPS resume

- **UWB Ranging** (optional, device-dependent)
  - Sub-10m precision on supported Android/iOS devices
  - Fallback to BLE/GPS on unsupported devices

- **Smartwatch Companion**
  - Wear OS app (simplified pinwheel)
  - watchOS app (simplified pinwheel)
  - Breach alerts → watch haptics

- **Privacy Audit**
  - Third-party security review
  - Formal differential privacy proof review
  - Penetration testing report

### Testing
- Integration tests for full Noise handshake
- Battery profiling (compare vs. map apps)
- Field trials in Pretoria parks (accuracy validation)
- Usability testing with 8–12 participants

---

## [0.3.0] — TBD (Release Candidate)

### Planned
- **Production Hardening**
  - Constant-time cryptographic operations
  - Secure memory clearing (no plaintext key leaks)
  - Comprehensive error handling

- **Platform Expansion**
  - Google Play Store release (Android)
  - Apple App Store release (iOS)
  - Web demo (Flutter Web, read-only)

- **Documentation**
  - API documentation (dartdoc)
  - User manual
  - Developer onboarding guide

### Testing
- Full test coverage (>85% code coverage)
- Continuous integration (GitHub Actions)
- Automated dependency scanning

---

## [1.0.0] — TBD (General Availability)

### Planned
- Full feature parity with design spec
- Multi-language support (i18n)
- Accessibility (a11y) improvements
- Performance optimization
- Community contributions integrated

---

## Deprecated Features

None currently.

---

## Migration Guides

None currently (MVP pre-release).

---

## Removed Features

None currently.

---

## Contributors

- **Botlhale Pono Maruma** — Creator, core implementation
- *Your name here* — (Contributions welcome!)