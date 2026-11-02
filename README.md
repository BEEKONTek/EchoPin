# EchoPin

Privacy-first peer presence for local sessions. Presence is relative, noisy,
and boundary-scoped — no raw coordinates ever leave the device.

## What it does

EchoPin lets a small group create or join a temporary "session." Each device
sees peers as bearing + distance from itself, inside a boundary circle the
user controls. When a peer crosses that boundary, the app surfaces an alert
(in-app banner, haptic, optional OS notification). Sessions are identified by
short human-friendly codes that can be shared as text or QR.

Nothing about the design requires trusting a server. Absolute locations are
never measured, never stored, and never transmitted.

## Features

- Create/join sessions via `ECHO-XXXX-XXXX-YY` codes (HMAC checksummed).
- Live pinwheel view of peer bearing/distance with a drag-adjustable boundary.
- Boundary alerts: in-app banner, haptic feedback, optional OS notification.
  Throttled to 5 s per peer to avoid spam.
- Privacy noise: peer positions are jittered per-peer, per-minute, before the
  UI ever sees them. Adjustable at runtime.
- Session history: last 20 sessions with one-tap rejoin.
- Admin panel: live diagnostics, synthetic peer injection, default radius and
  noise controls.
- Native BLE bridge (Kotlin + Swift) compiled into the release APK.

## Architecture

    lib/
      models/          immutable data (Session, PeerPresence, BoundaryAlert, ...)
      services/        pure logic + platform boundaries
        bootstrap      backend selection at startup, every probe has a fallback
        session_codec  HMAC-checksummed session codes
        secure_store   per-install secret (OS keystore, prefs migration)
        mesh_service   peer source; emits peerUpdates stream
        boundary_monitor  pure crossing detection (previous vs. current snapshot)
        notification_backend / local_notification_backend  OS notifications
        platform_ble_bridge / method_channel_ble_bridge    native BLE
      providers/       ChangeNotifiers: SessionProvider, AlertProvider
      screens/         home, session
      widgets/         pinwheel, boundary alert banner
    android/           Kotlin BLE plugin + manifest permissions
    ios/               Swift BLE plugin + Info.plist descriptions

Three `InheritedNotifier` scopes (`SessionScope`, `AlertScope`, and Bootstrap
output passed to `main`) expose providers to the tree without any external
state-management dependency. Writes go through explicit `*.read(context)`
calls so event handlers don't rebuild on every notify.

## Privacy model

Every claim below is enforced in code, not just documented:

- **Relative only.** `PeerPresence` stores `bearingDegrees` and
  `distanceMeters`. There is no field for absolute coordinates anywhere in
  the model.
- **Noisy by default.** `LocationEngine.applyNoise` jitters distance by a
  configurable sigma before `SessionProvider` ever sees the value. Default
  noise is 7 m; adjustable from the admin panel.
- **No persistence of peers or locations.** Only session metadata is written
  to disk (`session_history_service`), and only the code — never positions.
- **Session secret in OS storage.** The 32-byte HMAC key for session codes is
  generated per install and stored in `flutter_secure_storage`
  (EncryptedSharedPreferences on Android, Keychain on iOS), with a one-time
  migration from a legacy prefs store.
- **Codes are integrity, not access.** The checksum detects typos; it does
  not authenticate. Anyone with a code can join — that is the intended
  product semantics for a local presence session.

## Backend fallbacks

Every backend is probed at startup. A missing platform (web, CI, Linux
without libsecret) degrades to a working substitute — the app never fails to
launch.

| Capability | Primary | Fallback |
| --- | --- | --- |
| Secret storage | `SecureStorageKvStore` (OS keystore) | `PrefsKvStore` |
| OS notifications | `LocalNotificationBackend` | `NoopNotificationBackend` |
| BLE transport | `MethodChannelBleBridge` | `MeshService` simulation |

`Bootstrap.usingSecureStorage` and `Bootstrap.usingRealBle` report which path
was selected; the admin panel surfaces both.

## BLE protocol

- Advertise: manufacturer data `[sessionId(8) || peerId(8)]` UTF-8, 16 bytes.
- Scan: filter by session-id prefix, drop self.
- Distance: `10^((txPower - rssi) / 20)` with fixed `txPower = -59 dBm`.
- Direction: not available from BLE advertising. The peer is placed on a
  circle at `distance` with a stable angle derived from its peer id, so the
  dot doesn't jump between observations and no false bearing is implied.
- Stale pruning: 15 s without a packet removes the peer.

## Session codes

Format `ECHO-XXXX-XXXX-YY`. `XXXXXXXX` is a random 8-character id from an
unambiguous 29-character alphabet (no `0/O`, `1/I`, etc.); `YY` is a
two-character truncated HMAC-SHA256 checksum over the id. Parsing is
lenient by default: non-`ECHO` inputs pass through as ad-hoc ids, useful for
development. `SessionCodec.parse(code, lenient: false)` rejects them.

## Development

    flutter pub get
    flutter analyze          # must be clean
    flutter test             # 55+ tests
    flutter run              # or: flutter run -d linux / -d chrome

Force simulation regardless of platform BLE:

    flutter run --dart-define=ECHOPIN_FORCE_SIM=true

## Building

Android debug APK:

    flutter build apk --debug

iOS (requires macOS host):

    flutter build ios --no-codesign

Android build requirements (already configured in this repo):

- JDK 17 (`flutter config --jdk-dir /usr/lib/jvm/java-17-openjdk`)
- Core library desugaring enabled in `android/app/build.gradle.kts` —
  required by `flutter_local_notifications` for `java.time.*` on API < 26
- At least 4 GB usable RAM for the Gradle daemon
  (`android/gradle.properties` sets `-Xmx3G`)

## Testing

    test/
      models/      Session, PeerPresence, BoundaryAlert
      services/    SessionCodec, SessionHistoryService, SecureStore,
                   BoundaryMonitor, NotificationService
      providers/   AlertProvider, SessionProvider
      widgets/     home + session smoke tests
      session_model_test.dart    legacy LocationEngine coverage

`flutter analyze` is expected to report zero issues. Style lints
(`omit_local_variable_types`, `prefer_const_*`) are disabled in
`analysis_options.yaml` to match repo conventions; correctness lints
(`use_build_context_synchronously`, `await_only_futures`,
`unawaited_futures`) stay on.

## Status

What works end-to-end today:

- Session lifecycle, pinwheel rendering, boundary alerts, haptics,
  persistence, session history, admin panel.
- Native BLE Kotlin/Swift code compiles into the release APK; the platform
  channels are registered and respond to `ping`.
- The debug APK builds successfully and 55+ tests pass.

What is deliberately deferred (documented so it isn't mistaken for finished):

- **BLE to MeshService runtime wiring.** The bridge compiles and is callable;
  `MeshService` currently drives the UI with a simulated peer stream.
  Wiring the real bridge output into `MeshService.peerUpdates` is the next
  increment. `Bootstrap.usingRealBle` already reports the probe result.
- **iOS build verification.** The Swift bridge is source-complete but
  cannot be compiled on a Linux host. On macOS:
  `flutter build ios --no-codesign`.
- **Code-signing.** Release builds need `android/key.properties` and
  `ios/Runner.xcworkspace` signing configured externally.

## CI

Five workflows under `.github/workflows/`:

| File | Runs |
| --- | --- |
| `build.yml` | Android APK build |
| `ci.yml` | Aggregation summary |
| `dependency-check.yml` | Scheduled validation |
| `lint.yml` | `flutter analyze` + formatting |
| `test.yml` | Unit + widget tests, coverage upload |

All workflows trigger on `push` to `main`, `develop`, and `deepseek-mvp`.
`pull_request` triggers remain `main, develop` only — feature branches into
`main` should be deliberate, not every push.
