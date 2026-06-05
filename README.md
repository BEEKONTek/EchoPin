# EchoPin
Privacy-first, decentralized P2P location-sharing mobile app. Works fully offline with BLE mesh &amp; end-to-end encryption.

### Privacy Layer
- **Raw GPS** → **Obfuscated coordinates** (planar Laplace, ε=0.5)
- Only **relative bearing** + **relative distance** + **boundary status** broadcast
- **Zero absolute coordinates** transmitted

### Mesh Protocol
1. **BLE Advertising** — session UUID in service advertisement (no device name, no PII)
2. **BLE Discovery** — scan for session peers
3. **Noise XX Handshake** — mutual authentication, derive transport keys
4. **Encrypted Relay** — multi-hop message forwarding via libp2p
5. **Rate Limiting** — 2 updates/second per peer (DoS protection)
6. **Replay Protection** — nonce + timestamp validation

---

## Quick Start

### Prerequisites
- **Flutter 3.3+** ([install](https://flutter.dev/docs/get-started/install))
- **Dart 3.3+** (bundled with Flutter)
- **Android Studio** or **VS Code** + Flutter extension
- **Android device** (API 24+) or **iOS device** (14+)
- 2+ devices for testing (borrow from friends/family)

### Clone & Setup
```bash
git clone https://github.com/botlhalepono/echopin.git
cd echopin
flutter pub get
flutter run
```

### Create a Session
1. **Tap "Create session"** on the home screen
2. **You are now broadcasting** your position via BLE
3. **Other devices can scan the QR code** to join the same session

### Join a Session
1. **Ask a friend to show their QR code**
2. **Tap "Join via QR code"**
3. **Scan the QR**
4. **You now see them on the pinwheel**

### Set Boundary Radius
- **Slide the "Boundary" slider** to adjust the alert radius (50m–500m)
- **Breach happens?** Red banner + haptic buzz

---

## Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| **App** | Flutter 3.x | Cross-platform (Android + iOS); single codebase |
| **State** | flutter_riverpod | Lightweight, testable state management |
| **P2P Mesh** | flutter_blue_plus | BLE discovery + GATT (fallback if mesh unstable) |
| **WiFi Direct** | flutter_nearby_connections | High-bandwidth peer-to-peer upgrade |
| **Encryption** | Noise XX (cryptography package) | Mutual auth, forward secrecy |
| **Location** | geolocator + flutter_compass | GPS + magnetometer heading |
| **Privacy** | Planar Laplace noise | Geo-indistinguishability (lightweight) |
| **UI** | CustomPainter (Canvas) | Bespoke radial rendering |
| **QR** | qr_flutter + mobile_scanner | Session join, code generation |
| **Haptics** | vibration | Breach alerts |

---

## Project Status

**Phase:** MVP (Alpha) — Core features implemented  
**Version:** 0.1.0  
**Timeline:** May–October 2026 (24-week academic project)

| Phase | Milestone | Status |
|-------|-----------|--------|
| 1 | Requirements + Charter | Complete |
| 2 | Threat model + Figma mockup | Complete |
| 3 | Alpha MVP (core session + pinwheel) | In Progress |
| 4 | Beta (full fusion + privacy audit) | Planned |
| 5 | Release + usability testing | Planned |

See [ROADMAP.md](./docs/ROADMAP.md) for detailed timeline.

---

## Documentation

- **[Architecture](./docs/ARCHITECTURE.md)** — System design, threat model, privacy guarantees
- **[Setup Guide](./docs/SETUP.md)** — Development environment, running tests
- **[API Reference](./docs/API.md)** — LocationEngine, MeshService, Session models
- **[Roadmap](./docs/ROADMAP.md)** — Features, phases, research questions
- **[Requirements](./EchoPin_Requirements_Document.md)** — Full functional + non-functional specs

---

## Testing

### Unit Tests
```bash
flutter test
```

### Integration Tests
```bash
flutter test integration_test/
```

### Manual Testing (2+ devices)
1. **Device A:** Create session → show QR
2. **Device B:** Scan QR → join session
3. **Move apart** → verify distance updates
4. **Cross boundary** → verify haptic + red banner

---

## Privacy & Security

### What EchoPin Does **NOT** do
- Store location history
- Require user accounts or logins
- Phone home to servers
- Broadcast your real GPS coordinates
- Persist data after session exit

### What EchoPin Does
- Applies **planar Laplace noise** (ε=0.5) to hide exact position
- Only transmits **relative bearing** + **distance** (derived values)
- Encrypts all messages with **Noise XX** (mutual authentication)
- **Wipes all session data** on exit (keys, peers, timestamps)
- Rotates **ephemeral keys** per session

**See [SECURITY.md](./SECURITY.md) for detailed threat model + privacy analysis.**

---

## Contributing

We welcome contributions! Before you start:

1. **Read [CONTRIBUTING.md](./CONTRIBUTING.md)** for style guide + PR process
2. **Check [open issues](https://github.com/botlhalepono/echopin/issues)** for ideas
3. **Fork the repo** → create a feature branch
4. **Write tests** for new code
5. **Submit a pull request** with a clear description

### Current Help Wanted
- **UI/UX feedback** — test the pinwheel, suggest improvements
- **Mobile testing** — find bugs on Android/iOS devices
- **Documentation** — improve guides, add examples
- **Security review** — audit the Noise handshake or privacy proofs

---

## License

MIT License — see [LICENSE](./LICENSE) for details.

**tl;dr:** Use, modify, distribute freely. No warranty.

---

## Author

**Botlhale Pono Maruma** | Richfield Graduate Institute of Technology  
[402307375@my.richfield.ac.za](mailto:402307375@my.richfield.ac.za)  
[@botlhalepono](https://github.com/botlhalepono)

---

## Acknowledgments

- **Flutter & Dart teams** — amazing mobile framework
- **Cryptography community** — Noise protocol design, geo-indistinguishability research
- **Test participants** — usability feedback (TBD)

---

<div align="center">

**Built with love for privacy-respecting group presence.**

[Report Bug](https://github.com/botlhalepono/echopin/issues/new?labels=bug) · [Request Feature](https://github.com/botlhalepono/echopin/issues/new?labels=enhancement) · [View Roadmap](./docs/ROADMAP.md)

</div>
