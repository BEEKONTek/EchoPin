# Developer handoff

Where the project stands, the rules that must not be broken, how to prove
a change works, and what is still open. Read `README.md` first, then
`docs/CODE_MAP.md` for a guided tour of the code.

## Where things stand (0.5.0)

- The app runs real sessions over Bluetooth LE (verified between Android
  phones) and Wi-Fi: encrypted,
  signed, with check-ins, SOS, a 100 m pinwheel and a PIN-locked admin
  panel. Everything works with no server at all.
- The optional server (`server/`) adds verified accounts, device-bound
  sign-in, sealed emergency records opened only by audited break-glass,
  reports, a staff console, an append-only audit chain and encrypted
  backups. A free hosted deployment is described in `docs/DEPLOY_HOSTED.md`.
- Every input is length-capped in the app and re-checked on the server;
  see `docs/IMPLEMENTATION.md` §5.3 for the validation matrix.

## Ground rules

- **No coordinates anywhere.** Distance comes only from local signal
  strength; nothing location-like is sent, stored or logged, not even in
  sealed records.
- Native code moves opaque bytes; all cryptography stays in Dart
  (`lib/security`, `packages/echopin_protocol`), with standard primitives
  only (HKDF-SHA256, XChaCha20-Poly1305, Ed25519, X25519, Argon2id).
  Change a wire format only together with `docs/PROTOCOL.md` and a version
  bump.
- Every failure is typed and carries a human sentence (`EchoError` in the
  app, `ApiException` on the server). Clients never see stack traces or
  database wording.
- Real sessions never show simulated people; demo mode is explicit.
- The server never trusts the app: limits, shapes and roles are enforced
  again on every request (`server/lib/src/api/http.dart`).
- Don't `await` `cancel()`/`close()` of broadcast streams in test
  teardown: their futures complete in the root zone and hang widget tests.

## Verify before claiming done

    flutter analyze                           # whole tree, nested packages too
    dart format --output=none --set-exit-if-changed lib test integration_test
    flutter test                              # app: unit + widget
    (cd server && tool/test.sh)               # server: throwaway PostgreSQL + all tests
    (cd server && tool/live_check.sh)         # system test over HTTP, 31 checks
    (cd packages/echopin_protocol && dart test)
    xvfb-run -a flutter test integration_test/lan_transport_test.dart -d linux
    flutter build apk --release && flutter build linux --release && flutter build web --release

## Open work

1. **Android with an iPhone.** Android to Android is verified in the
   field (`docs/IMPLEMENTATION.md`, part F). The iOS side follows
   CoreBluetooth's rules but has not met an Android radio; watch MTU
   negotiation, chunk reassembly and the 10 s job timeout.
2. **iOS and macOS on a Mac** (`flutter build ios --no-codesign`; CI builds
   them unsigned). A signed build needs a bundle id you own, not
   `com.example`, and the same goes for Android's `applicationId` before
   any store release.
3. **Windows build.** CI's Windows job fails and no Windows host was
   available to read why; the job is marked non-blocking until someone
   with Windows can look.
4. **Background operation.** Discovery runs while the app is open. iOS
   does not advertise local names in the background; Android may pause
   scans with the screen off. Needs a foreground service (Android) and
   service-UUID advertising (iOS).
5. **Direction and exact distance.** Signal strength gives an approximate
   distance only, as the field test confirmed. Real arrows and metre-level
   figures need ultra-wideband (iPhone 11+, some Android flagships):
   native ranging plus a `hasBearing: true` presence from it.
6. **Forward secrecy** within a session would need per-pair key exchange
   (`docs/PROTOCOL.md` §8).
7. **OS deep links**, so a camera-app scan of an invite opens EchoPin.
8. **Erasure policy.** Accounts that have opened records cannot be deleted
   (a deliberate foreign key); decide how to honour deletion requests.
