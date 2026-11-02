# EchoPin Agent Handoff Package

## Project status
- Repository: `BEEKONTek/EchoPin`
- Current repo state: minimal Flutter starter, with `lib/main.dart` as the only file under `lib/` at the checked snapshot.
- The design docs and handoff notes describe a much larger app than the current codebase contains.
- This handoff package is intended for a follow-up agent to continue from the current skeleton without re-deriving the requirements.

## Token warning threshold
- Trigger warning when model usage reaches approximately 70% of the available allocation.
- At that point, the active agent should preserve work, summarize progress, and stop before the remaining context becomes unsafe for a full continuation.
- The follow-on agent should continue from this package and the repo state instead of trying to re-infer missing work.

## What is known to be true
- App is a Flutter app named `echo_pin`.
- The current code is a startup `Hello World` app in `lib/main.dart`.
- The design specification is the authoritative product specification: `DESIGN_DIGEST.md`, `OPEN_ITEMS.md`, and `TEST_SPEC.md` are the source of functional requirements.
- The repo is expected to grow toward:
  - session creation/join flow
  - geolocation + privacy-noise logic
  - mesh networking and message validation
  - BLE and QR flows
  - UI for pinwheel + boundary + breach banner
  - tests for the spec IDs described in `TEST_SPEC.md`

## Immediate implementation priority
1. Duplicate the current app skeleton into a proper architectural layout:
   - `lib/main.dart`
   - `lib/models/`
   - `lib/services/`
   - `lib/widgets/`
   - `lib/providers/`
2. Implement the minimum working session model and service layer that matches the design digest.
3. Implement the location engine according to the privacy/noise requirements.
4. Implement presence broadcasting and mesh validation.
5. Implement the session screen and pinwheel UI.
6. Add unit/widget coverage aligned to `UT-*` and `WT-*` IDs.
7. Fix the repo-level itemization in `OPEN_ITEMS.md` as work closes out.

## Minimum viable build target
The next agent should aim for these outcomes before trying to chase broader polish:
- `flutter pub get` succeeds
- `flutter analyze` is clean or close to clean
- app opens and shows a session creation flow
- code generation and state model are consistent with the design digest
- peer presence rules, radius logic, and stale peer handling are implemented
- tests compile and a meaningful subset passes

## Concrete file candidates to create
- `lib/models/session.dart`
- `lib/services/location_engine.dart`
- `lib/services/mesh_service.dart`
- `lib/widgets/pinwheel_painter.dart`
- `lib/screens/home_screen.dart`
- `lib/screens/session_screen.dart`

## Important constraints
- Do not invent custom crypto or re-define the protocol outside the design docs.
- Respect the stated security requirement: no plaintext location leaves the device.
- Keep the session in-memory only unless a later requirement explicitly adds persistence.
- The app should remain local/offline-first.

## Suggested continuation prompt for the next agent
"Continue the EchoPin Flutter app from the current repo skeleton. Use the design digest and test spec as the source of truth. Implement the missing model/service/UI layers required for a working MVP, keep the app offline-first, and prioritize a buildable state before additional feature polish. Preserve the `echo_pin` package name and follow the design constraints in `DESIGN_DIGEST.md` and `TEST_SPEC.md`."

## Known gaps to resolve
- Real QR implementation
- Noise XX handshake implementation
- BLE/Wi-Fi Direct transport decisions and implementations
- State-provider refactoring per `OPEN_ITEMS.md`
- CI job setup
- Browser/desktop build verification

## Ending instruction
If the active agent reaches the 70% threshold before the project is complete, it should stop, summarize all remaining work, and pass this file forward with a brief changelog of what has been implemented and what remains.
