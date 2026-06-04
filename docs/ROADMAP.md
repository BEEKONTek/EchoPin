# EchoPin Product Roadmap

## Vision

EchoPin evolves from MVP (core decentralized presence) → Production-ready group proximity awareness tool trusted by outdoor enthusiasts, event organizers, and families worldwide.

---

## Timeline

**Project Duration:** May 2026 – October 2026 (24 weeks)  
**Status:** Phase 3 (Alpha MVP) — Core features implemented

---

## Phase 1: Foundation ✅ (Weeks 1–3)

### Completed
- [x] Requirements document + project charter
- [x] Technology stack finalization
- [x] Project structure + GitHub setup
- [x] Core data models (Session, Peer, LocationEngine stubs)

### Deliverables
- Requirements Document (D1)
- Project Charter
- GitHub repository initialized

---

## Phase 2: Design & Architecture ✅ (Weeks 4–8)

### Completed
- [x] Threat model (STRIDE + LINDDUN)
- [x] Privacy specification (planar Laplace noise)
- [x] High-fidelity Figma prototype
- [x] Architecture specification document
- [x] API design (LocationEngine, MeshService, Session models)

### Deliverables
- Threat Model (D2)
- Figma Prototype (D3)
- Architecture Specification (D4)

---

## Phase 3: Alpha MVP 🔄 (Weeks 9–18)

### Current Work (Weeks 9–14)

#### Core Session Management
- [x] `EchoSession.create()` — create ephemeral sessions
- [x] Session auto-expire (8 hours)
- [x] QR code generation (placeholder UI)
- [x] Session data wipe on exit
- [ ] QR code scanning (via mobile_scanner)

#### Location Engine
- [x] GPS + compass heading integration (streams)
- [x] Planar Laplace noise obfuscation (ε=0.5)
- [x] Haversine bearing & distance computation
- [x] BLE RSSI fallback distance estimation (stub)
- [ ] IMU dead-reckoning integration (full)

#### Mesh Networking (Stubs)
- [x] BLE advertising structure (no PII)
- [x] BLE discovery simulation
- [x] Noise XX handshake skeleton
- [x] Message rate limiting (token bucket per peer)
- [x] Replay attack protection (nonce + timestamp)
- [x] Session size cap enforcement (20 peers max)
- [ ] Real flutter_blue_plus BLE implementation
- [ ] Real Noise XX encryption (dart_libp2p)
- [ ] Wi-Fi Direct upgrade path
- [ ] Multi-hop message relay

#### Radial Pinwheel UI
- [x] CustomPainter rendering (arms, dots, boundary ring)
- [x] Breach detection visual (red banner + pulsing ring)
- [x] Direction + distance encoding on arms
- [x] Haptic feedback on breach (HapticFeedback.heavyImpact)
- [x] Dark/light mode support
- [x] Peer emoji labels + distance labels
- [x] Boundary slider (50m–500m)
- [x] Cardinal direction labels (N/S/E/W)
- [ ] Tap-to-inspect peer details popup
- [ ] Animation polish (smooth transitions)

#### Testing (MVP)
- [x] Unit tests for LocationEngine (noise, bearing, distance)
- [x] Unit tests for MeshService (rate limiting, replay)
- [x] Widget tests for PinwheelPainter
- [x] Integration test skeleton (session lifecycle)
- [ ] Full integration test suite (BLE + UI)
- [ ] Manual usability testing (8–12 participants)

### Deliverable (Week 14)
- **D5: Working Alpha MVP** (APK on GitHub Releases)
  - Create session → show QR → see simulated peers on pinwheel
  - Boundary breach detection + haptic feedback
  - Location privacy via Laplace noise

---

### Beta Phase (Weeks 15–18)

#### Networking Hardening
- [ ] Real Noise XX implementation (using dart_libp2p)
- [ ] Actual BLE encryption payload transmission
- [ ] Wi-Fi Direct peer-to-peer upgrade
- [ ] Multi-hop relay message validation
- [ ] Constant-time distance calculations (timing-safe)

#### Location Fusion
- [ ] Full IMU integration (accelerometer + gyroscope)
- [ ] Step detection for dead-reckoning
- [ ] Heading integration from gyroscope
- [ ] Error drift correction when GPS resumes

#### Privacy Audit
- [ ] Third-party security code review
- [ ] Formal differential privacy proof validation
- [ ] Penetration testing report

#### Field Trials
- [ ] Accuracy validation (Pretoria parks)
  - GPS-only mode: target <20m error at 95th percentile
  - BLE fallback: target <200m error at 95th percentile
- [ ] Battery profiling vs. map apps
- [ ] Multi-device mesh relay testing (3–5 hops)

### Deliverable (Week 18)
- **D6: Beta MVP** (APK + iOS on GitHub Releases)
  - Full Noise XX encryption (real data)
  - BLE + Wi-Fi Direct networking
  - Private security audit report
  - Field trial results (accuracy, battery)

---

## Phase 4: Hardening & Release 🔄 (Weeks 19–22)

### Production Readiness
- [ ] Error handling audit (all code paths)
- [ ] Secure memory clearing (no plaintext key leaks)
- [ ] Dependency security scan (automated via GitHub Actions)
- [ ] Test coverage >85% (core services >90%)
- [ ] Comprehensive logging (no PII in logs)

### Platform Expansion
- [ ] Google Play Store submission (Android)
- [ ] Apple App Store submission (iOS)
- [ ] Web demo version (Flutter Web, read-only)
- [ ] Smartwatch companion (Wear OS + watchOS)
  - Simplified pinwheel display
  - Breach alert haptics
  - Session join code on watch

### Documentation
- [ ] API documentation (dartdoc)
- [ ] User manual (in-app help + PDF)
- [ ] Developer onboarding guide
- [ ] Video tutorials (setup, usage)
- [ ] Troubleshooting FAQ

### Testing & QA
- [ ] Beta testing with 20–30 external users
- [ ] Bug fixes from user feedback
- [ ] Performance optimization (battery, latency)
- [ ] Accessibility audit (a11y)

### Deliverable (Week 22)
- **D7: Test Report + Release Build** (v1.0.0-rc.1)
  - Final bug fixes
  - Comprehensive test report
  - Security audit report
  - User manual

---

## Phase 5: General Availability 📋 (Weeks 23–24)

### Final Steps
- [ ] Address Play Store / App Store review feedback
- [ ] Release v1.0.0 on both stores
- [ ] Final documentation polish
- [ ] GitHub repository finalization
- [ ] Academic thesis / paper submission

### Deliverable (Week 24)
- **D8: Final Report + GitHub Release** (v1.0.0)
  - Public GitHub repository (MIT license)
  - Academic final report
  - Live app on Play Store + App Store

---

## Future Enhancements (Post-Release)

### Optional Features
- [ ] **UWB Ranging** — sub-10m precision (device-dependent)
- [ ] **Mesh Routing Optimization** — dynamic path selection
- [ ] **Custom Boundary Alerts** — different radii per peer
- [ ] **Temporal History** — replay past movement (privacy-aware)
- [ ] **Multi-language Support** (i18n)
- [ ] **Accessibility Improvements** (a11y)
- [ ] **Desktop Companion** (Windows/Mac observer mode)
- [ ] **zk-SNARK Privacy** (long-term research)

---

## Success Metrics

| Metric | Target | Status |
|--------|--------|--------|
| **Accuracy (GPS)** | <20m error @ 95%ile | ⏳ Field trial (Beta) |
| **Accuracy (BLE)** | <200m error @ 95%ile | ⏳ Field trial (Beta) |
| **Battery Impact** | <20% extra drain over 4h | ⏳ Profiling (Beta) |
| **Location Latency** | <3 seconds E2E | ⏳ Integration test |
| **Session Join Time** | <10 seconds QR → display | ⏳ Manual test |
| **Pinwheel Readability** | Glance time <1.5 seconds | ⏳ Usability test (n≥8) |
| **Code Coverage** | >85% (core >90%) | ⏳ Phase 4 |
| **Security Audit** | Pass third-party review | ⏳ Phase 3 (Beta) |
| **Privacy Noise** | ε=0.5, ~50m plausible deniability | ✅ Implemented |

---

## Blockers & Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| flutter_mesh_network too immature | High | High | Fallback: flutter_blue_plus + flutter_nearby_connections |
| <8 participants for usability test | Medium | Medium | Use 5-person Nielsen threshold; supplement with cognitive walkthrough |
| UWB hardware unavailable | Medium | Low | BLE-only fallback; UWB remains optional |
| GPS inaccuracy indoors | High | Medium | Document limitation; test outdoors only |
| Play Store review delays | Medium | Low | Submit 4 weeks before target release |
| Third-party security audit cost | Low | High | Use pro-bono options or skip if budget unavailable |

---

## Contributing to Roadmap

Community contributions welcome! Priorities:
1. **BLE implementation** — real flutter_blue_plus integration
2. **Noise XX encryption** — dart_libp2p Noise protocol
3. **Testing** — additional unit/integration tests
4. **Documentation** — improve guides, add examples
5. **UX feedback** — usability testing, design suggestions

See [CONTRIBUTING.md](../CONTRIBUTING.md) for how to help.

---

## Questions?

- **Timeline questions?** Email: 402307375@my.richfield.ac.za
- **Feature requests?** Open a [GitHub issue](https://github.com/BEEKONTek/echopin/issues)
- **Want to help?** See [CONTRIBUTING.md](../CONTRIBUTING.md)

---

*Last updated: June 2026*  
*Next review: End of Phase 3 (Week 14)*