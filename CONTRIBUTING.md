# Contributing to EchoPin

Thank you for your interest in contributing to EchoPin! We welcome contributions from developers, designers, researchers, and testers.

## Code of Conduct

Please read our [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) before contributing. We are committed to fostering an inclusive and respectful community.

---

## How to Contribute

### 1. Report a Bug
**Found a bug?** [Open an issue](https://github.com/botlhalepono/echopin/issues/new?labels=bug) with:
- Clear description of the problem
- Steps to reproduce
- Expected vs. actual behaviour
- Device info (Android/iOS version, device model)
- Screenshots or logs if applicable

### 2. Request a Feature
**Have an idea?** [Open an issue](https://github.com/botlhalepono/echopin/issues/new?labels=enhancement) with:
- Clear description of the feature
- Why it would be useful
- Example use case
- Rough implementation idea (optional)

### 3. Submit Code

#### Fork & Clone
```bash
git clone https://github.com//echopin.git
cd echopin
git checkout -b feature/your-feature-name
```

#### Style Guide

**Dart/Flutter Code:**
- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart) conventions
- Use `flutter analyze` to check for issues
- Run `dart format .` to auto-format code
- Keep lines < 80 characters where possible
- Use meaningful variable names (avoid `a`, `b`, `temp`)
- Add comments for complex logic

**Naming Conventions:**
- Classes: `PascalCase` (e.g., `LocationEngine`, `MeshService`)
- Functions/methods: `camelCase` (e.g., `computeBearing()`)
- Constants: `camelCase` with `const` keyword (e.g., `const double _epsilon = 0.5`)
- Private members: prefix with `_` (e.g., `_lastPosition`)

**Comments:**
```dart
/// Public API documentation (triple slash for public methods/classes)
///
/// Explains what this does, parameters, return value, and edge cases.
void myPublicFunction() {}

// Regular comments for implementation details
final x = value; // inline comments are okay too
```

#### Write Tests
- Add **unit tests** for business logic (location, encryption, mesh)
- Add **widget tests** for UI components
- Add **integration tests** for end-to-end flows
- Aim for >80% code coverage on core services

```bash
# Run all tests
flutter test

# Run with coverage
flutter test --coverage

# Run a specific test file
flutter test test/unit/location_engine_test.dart
```

#### Lint & Format
```bash
# Check for issues
flutter analyze

# Auto-format code
dart format lib/ test/

# Fix common issues
dart fix --apply
```

#### Create a Pull Request
1. **Push your branch:**
```bash
   git add .
   git commit -m "feat: add feature description"
   git push origin feature/your-feature-name
```

2. **Open a PR on GitHub** with:
   - Clear title: `feat: ...` or `fix: ...` (follow [Conventional Commits](https://www.conventionalcommits.org/))
   - Description of changes
   - Link to related issue (e.g., `Closes #42`)
   - Screenshots for UI changes
   - Any breaking changes clearly noted

3. **Address review feedback** gracefully and update your PR

4. **Merge** once approved

---

## Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

<type>(<scope>): <subject>
<body>
<footer>
````
Types:

feat: New feature
fix: Bug fix
docs: Documentation
refactor: Code refactoring (no feature change)
test: Add/update tests
chore: Build, CI, dependency updates
perf: Performance improvement

Examples:
feat(mesh): add rate limiting per peer

Implement token-bucket rate limiter to prevent DoS via update flooding.
Max 2 updates/second per peer. Adds _RateLimiter class.

Closes #15
fix(ui): pinwheel not updating when peer moves

The pinwheel was caching peer positions. Now rebuilds on every presence
update. Added shouldRepaint override to PinwheelPainter.

Closes #8

Areas We Need Help
UI/UX

Test the pinwheel on different screen sizes
Suggest design improvements for accessibility
Help with dark mode, high-contrast mode
Improve icon/emoji choices

Testing

Test on Android devices (especially API 24–28)
Test on iOS devices
Find edge cases (GPS loss, sudden disconnections)
Battery drain profiling

Documentation

Improve code comments
Add more API examples
Create video tutorials
Expand troubleshooting guide

Security

Review threat model and privacy guarantees
Audit the Noise XX handshake
Test against known attacks
Suggest hardening measures

Localization

Translate UI strings to other languages
Adapt for regional requirements


Development Setup
Requirements

Flutter 3.3+ (install guide)
Dart 3.3+ (bundled with Flutter)
Android Studio or VS Code
2+ test devices

Running the App
bashflutter pub get
flutter run
Running Tests
bashflutter test              # All tests
flutter test test/unit/  # Only unit tests
Checking Code Quality
bashflutter analyze
dart format lib/
dart fix --apply

Questions?

Check the docs/ folder for architecture, API, setup guides
Read the README.md for overview
Open an issue to discuss ideas
Contact: @botlhalepono


Attribution
When we merge your PR, we'll add your name to:

The README.md acknowledgments
The CHANGELOG.md release notes
GitHub contributors graph

Thank you for making EchoPin better! 🎉