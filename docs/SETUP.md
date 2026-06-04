# EchoPin Development Setup

## Prerequisites

### Required
- **Flutter 3.3+** — [Install](https://flutter.dev/docs/get-started/install)
- **Dart 3.3+** — bundled with Flutter
- **Git** — [Install](https://git-scm.com/)
- **2+ test devices** — Android (API 24+) or iOS (14+)
  - Can borrow from friends/family; must have Bluetooth

### Optional
- **Android Studio** — IDE + emulator (limited BLE support)
- **VS Code** — lightweight editor + Flutter extension
- **Xcode** — required for iOS development (macOS only)

---

## Installation Steps

### 1. Clone the Repository

```bash
git clone https://github.com/BEEKONTek/echopin.git
cd echopin
```

### 2. Install Flutter & Verify

```bash
flutter --version
# Expected output: Flutter 3.24.0 or higher

dart --version
# Expected output: Dart 3.24.0 or higher
```

If not installed, follow [flutter.dev/install](https://flutter.dev/docs/get-started/install).

### 3. Get Project Dependencies

```bash
flutter pub get
```

This reads `pubspec.yaml` and downloads all packages into `pubspec.lock`.

### 4. Check Environment

```bash
flutter doctor -v
```

**Expected output:**
Flutter (Channel stable, 3.24.0)
Android SDK / Xcode (for your platform)
Android toolchain (for Android) or Xcode (for iOS)
Dart SDK
Chrome (for web)

Fix any [x] warnings before proceeding.

---

## Running the App

### On Android Device

1. **Connect device via USB** → Enable USB debugging (Settings > Developer Options > USB Debugging)
2. **Verify connection:**
```bash
   flutter devices
```
   Should list your device.

3. **Run the app:**
```bash
   flutter run
```
   - Wait for app to compile (~1–2 minutes on first run)
   - App launches automatically
   - Hot reload available: save code → see changes instantly (press `r` in terminal)

### On iOS Device

1. **Mac only.** Connect device via USB.
2. **Trust the device:**
   - Unlock phone, tap "Trust" when prompted
   - Unlock keychain on Mac (System Preferences > Security & Privacy)

3. **Run the app:**
```bash
   flutter run
```

### Troubleshooting Runs

| Issue | Fix |
|-------|-----|
| `Device not found` | Check `flutter devices`; restart device; check USB cable |
| `Permission denied` | Enable USB debugging (Android); unlock keychain (iOS) |
| `Gradle build failed` | Run `flutter clean && flutter pub get` |
| `Xcode build failed` | Run `cd ios && pod install && cd ..` |

---

## Code Quality

### Run Analysis (Linting)

```bash
flutter analyze
```

Reports code style issues, unused imports, potential bugs.

**Fix automatic issues:**
```bash
dart fix --apply
```

### Format Code

```bash
dart format lib/ test/
```

Automatically reformats code to style guide (80-char lines, spacing, etc.).

### Check Everything

```bash
# In one command:
flutter analyze && dart format lib/ test/ && flutter test
```

---

## Running Tests

### Unit & Widget Tests

```bash
flutter test
```

Runs all tests in `test/` folder.

**Specific test file:**
```bash
flutter test test/unit/location_engine_test.dart
```

**With coverage:**
```bash
flutter test --coverage
```

Coverage report is saved to `coverage/lcov.info`.

### Integration Tests

```bash
flutter test integration_test/
```

Full app end-to-end tests. Requires real device or emulator.

### Test Coverage Report

```bash
# Generate coverage report (Mac/Linux)
flutter test --coverage
lcov --list coverage/lcov.info

# Or open in VS Code with "Coverage Gutters" extension
```

**Coverage targets:**
- Core services (LocationEngine, MeshService): >80%
- UI widgets: >60%
- Models: >90%

---

## Project Structure
echopin/
├── lib/
│   ├── main.dart                  # App entry point, theme
│   ├── models/
│   │   ├── session.dart           # Session, Peer, SessionKeys
│   │   └── ...
│   ├── services/
│   │   ├── location_engine.dart   # GPS + Laplace noise
│   │   ├── mesh_service.dart      # BLE + Noise XX
│   │   └── ...
│   ├── screens/
│   │   ├── home_screen.dart       # Create/join session
│   │   └── session_screen.dart    # Pinwheel + peer list
│   └── widgets/
│       ├── pinwheel_painter.dart  # CustomPainter
│       └── ...
├── test/
│   ├── unit/
│   │   ├── location_engine_test.dart
│   │   ├── session_test.dart
│   │   └── mesh_service_test.dart
│   └── widget/
│       ├── pinwheel_painter_test.dart
│       └── home_screen_test.dart
├── integration_test/
│   └── app_test.dart              # Full app lifecycle test
├── docs/
│   ├── ARCHITECTURE.md
│   ├── API.md
│   ├── SETUP.md (this file)
│   ├── ROADMAP.md
│   └── THREAT_MODEL.md
├── pubspec.yaml                    # Dependencies + metadata
├── pubspec.lock                    # Locked versions
├── analysis_options.yaml           # Linting rules
├── README.md
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── SECURITY.md
├── CHANGELOG.md
└── LICENSE

---

## Debugging

### Debug Logs

Add `print()` statements in code:

```dart
void myFunction() {
  print('[DEBUG] myFunction called');
  print('location: $location');
}
```

View in **Debug Console** in VS Code or Android Studio.

### Breakpoints

1. Click line number in VS Code to set breakpoint
2. Run app in debug mode:
```bash
   flutter run
```
3. App pauses at breakpoint
4. Step through code (F10), inspect variables
5. Resume (F5)

### Performance Profiling

```bash
flutter run --profile
```

In DevTools, open **Performance** tab to trace frame rendering time.

**Check for jank (dropped frames):**
- Pinwheel should repaint at 60 FPS (every ~16ms)
- If >50ms, profile which method is slow

---

## Git Workflow

### Branch for Features

```bash
git checkout -b feature/your-feature-name
# Make changes
git add .
git commit -m "feat: describe what you did"
git push origin feature/your-feature-name
```

Then open a **Pull Request** on GitHub.

### Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):
feat(mesh): add rate limiting per peer
fix(ui): pinwheel not updating on scroll
docs(setup): add troubleshooting section
test(location): validate Laplace noise radius
chore(deps): update flutter_blue_plus to 1.34.0

---

## Common Tasks

### Add a New Dependency

```bash
flutter pub add package_name
```

Or manually edit `pubspec.yaml`:
```yaml
dependencies:
  flutter:
    sdk: flutter
  new_package: ^1.2.0
```

Then run:
```bash
flutter pub get
```

### Upgrade Dependencies

```bash
flutter pub upgrade
```

Check for breaking changes in `CHANGELOG.md` of each package.

### Generate Code (if using code generation)

```bash
flutter pub run build_runner build
```

(Not needed for current MVP; prepare for future use.)

---

## Troubleshooting

### "flutter: command not found"

Add Flutter to PATH:

**macOS/Linux:**
```bash
export PATH="$PATH:~/flutter/bin"
```

**Windows:**
Add `C:\flutter\bin` to System Environment Variables → PATH.

### "Android SDK not found"

```bash
flutter doctor --android-licenses
# Accept all licenses
flutter doctor
```

### "iOS deployment target mismatch"

```bash
cd ios
pod repo update
pod install
cd ..
flutter run
```

### "BLE not working on Android emulator"

Emulator has limited BLE support. **Use a real Android device for testing.**

### "Tests fail on emulator"

Some tests require real device (GPS, BLE, compass). Run on physical device:

```bash
flutter devices
flutter test -d <device_id>
```

---

## Next Steps

1. **Read [ARCHITECTURE.md](./ARCHITECTURE.md)** — understand system design
2. **Read [API.md](./API.md)** — reference for models & services
3. **Run tests** — `flutter test`
4. **Make a small change** — edit a string in `HomeScreen`, hot reload
5. **Read [CONTRIBUTING.md](../CONTRIBUTING.md)** — before submitting code

---

## Support

- **Stuck?** Check [GitHub Issues](https://github.com/BEEKONTek/echopin/issues)
- **Questions?** Email: 402307375@my.richfield.ac.za
- **Found a bug?** Report privately (see [SECURITY.md](../SECURITY.md))