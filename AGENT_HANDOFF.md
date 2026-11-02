# EchoPin agent handoff

Status: compact handoff package; repo is a default Flutter starter, not a finished MVP.

## Current state
- Repo: BEEKONTek/EchoPin
- Current app is the generated Flutter Hello World app.
- Flutter dependencies are minimal and buildable only after the default starter is adapted to EchoPin branding and minimal UI shell.
- The design docs in the task context describe a richer EchoPin app, but the codebase does not yet implement it.

## What is already known
- App identity should be EchoPinLocator in user-facing strings.
- Android/iOS app metadata should match this brand name without changing the repo/package identifiers unless explicitly needed.
- The project has a design digest and test specs, but not the matching app implementation.

## What to do next
1. Update `lib/main.dart` to a minimal EchoPinLocator app shell.
2. Fix Android/iOS display names and app metadata.
3. Add a lightweight session model and a mock mesh/session state for screen-level functionality.
4. Add the Home -> Session flow with a visible session code and placeholder peer list.
5. Add tests only for the core shell and model logic.
6. Do not claim any advanced security or BLE features are implemented unless the code actually supports them.

## Do not over-claim
- No real Noise XX transport is present.
- No BLE mesh implementation exists yet.
- No QR join or real security stack is implemented yet.
- This is a partial app shell, not a complete MVP.

## Continuation prompt

Continue from this repo as a Flutter app scaffold for EchoPinLocator.

Requirements:
- Keep the repo name, Dart package name, and application identifiers stable unless a direct build issue forces a minor change.
- Set all user-visible app names to EchoPinLocator.
- Build a minimal but working app shell with:
  - Home screen with Create session and Join via QR
  - Session screen with session code visible
  - peer list / boundary ring placeholder
  - mock state and logic so the app runs without crash
- Use the task context design docs as the source of truth for intended behavior.
- If a feature is not implemented, leave it clearly marked as TODO or stub.
- Prefer correctness and buildability over speculative implementation.
- Keep the code readable and small enough to continue from easily.

## Exact next commands
```bash
flutter pub get
flutter analyze
flutter test
```

## Deliverable expectation
The next AI should leave the repo in a buildable, branded, minimally working state, with honest blockers documented rather than implied as complete.
