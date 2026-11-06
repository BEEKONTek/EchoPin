# EchoPin handoff

## Where things stand

EchoPin is a working Flutter app, past the demo stage: encrypted sessions
over Bluetooth LE and Wi-Fi, pings and SOS, a PIN-protected admin system,
and a minimal animated UI. The design brief is `README.md` together with
`docs/ARCHITECTURE.md`, `docs/PROTOCOL.md` and `docs/THREAT_MODEL.md`. The
`DESIGN_DIGEST.md`, `OPEN_ITEMS.md` and `TEST_SPEC.md` files referenced by
older notes do not exist.

## Ground rules

- No coordinates anywhere. Distance comes only from local RSSI.
- Native code moves opaque bytes; all crypto stays in Dart (`lib/security`).
- Use standard primitives only (HKDF-SHA256, XChaCha20-Poly1305, Ed25519 via
  `package:cryptography`). Change the wire format only together with
  `docs/PROTOCOL.md` and a version bump.
- Every failure is an `EchoError` with a human sentence (`lib/core`).
- Real sessions never show simulated people; demo mode is explicit.
- Don't `await` `cancel()`/`close()` of broadcast streams in teardown: their
  futures complete in the root zone and hang widget tests (FakeAsync).

## Verify before claiming done

    flutter analyze
    flutter test
    flutter test integration_test -d linux    # needs avahi
    flutter build apk --release && flutter build web && flutter build linux

## Open work

1. **Run Bluetooth on real phones**: Android↔Android, then Android↔iPhone.
   The GATT code compiles for Android and follows CoreBluetooth's rules,
   but has not met real radios. Watch MTU negotiation, chunk reassembly and
   the 10 s job timeout.
2. **Build iOS/macOS** on a Mac (`flutter build ios --no-codesign`); CI
   does this on macOS runners.
3. **Background operation**: foreground service on Android, service-UUID
   advertising for iOS background.
4. **Forward secrecy** within a session would need per-pair key exchange
   (see `docs/PROTOCOL.md` §8).
5. **OS deep links** so a camera-app scan of an invite opens EchoPin.
