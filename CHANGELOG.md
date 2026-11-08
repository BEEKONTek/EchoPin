# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed
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