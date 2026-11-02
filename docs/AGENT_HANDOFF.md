# EchoPin continuation handoff package

This file is intentionally kept lightweight and actionable so a follow-up agent can continue the project without re-discovering the repo state.

## Repo status
- Current app is a Flutter starter, not a completed EchoPin MVP.
- The generated app shell is working and buildable for the first phase.
- Missing or stubbed functionality remains in the areas of transport, QR scan, mesh networking, and secure transport.

## Current baseline
- App name: EchoPinLocator
- Session model class exists and is used by the shell UI.
- A prototype session screen and pinwheel display are present.
- No production-grade Noise, BLE, QR, or mesh layer is implemented yet.

## Ordered implementation plan
1. Build the real session and state architecture.
2. Implement QR join and creator flows.
3. Add transport abstraction (BLE + Wi-Fi Direct fallback).
4. Add secure transport and Noise XX handshake flow.
5. Add rate limiting, replay prevention, and peer-capping logic.
6. Finish the boundary logic and breach alert behavior.
7. Add validation tests and CI pipeline compliance.
8. Final polish and release configuration.

## Key files to review next
- lib/main.dart
- lib/models/session.dart
- android/app/src/main/AndroidManifest.xml
- ios/Runner/Info.plist

## Next-agent prompt
Use the current repo and implement the first production phase in order:
- keep the app buildable at each step
- preserve the EchoPinLocator naming
- implement a real session model with expiry, peer tracking, and boundary status
- add QR generation and QR join handling
- then implement the transport abstraction layer and secure message flow
- do not invent crypto or protocol behavior that is not validated
- proceed in series, not parallel

## Completion note
This handoff package is meant to be used when the remaining token budget is no longer sufficient to safely complete the full project. It should be treated as a continuation file, not as a completed MVP.
