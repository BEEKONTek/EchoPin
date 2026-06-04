# Security Policy

## Overview

EchoPin prioritizes **user privacy and data security** as core design principles. This document outlines our security model, threat assumptions, and responsible disclosure process.

## Security Model

### What We Protect

**Location Privacy**
- Absolute GPS coordinates are **never** transmitted
- Only **relative bearing** (direction) + **distance** (metres) are shared
- Coordinates are obfuscated with **planar Laplace noise** (ε=0.5)
- Expected noise radius ≈ 4m; 95th percentile plausible deniability within ~50m

**End-to-End Encryption**
- All messages encrypted with **Noise XX protocol**
- Mutual authentication between peers
- Forward secrecy via ephemeral key rotation per session

**Ephemeral Sessions**
- No persistent user accounts
- All session data wiped on exit
- Encryption keys never stored to disk
- Session auto-expires after 8 hours (configurable)

**Offline Operation**
- Zero server dependency — works with zero internet
- No cloud backend, no user tracking, no analytics

### What We Don't Protect

**Local Device Security**
- If attacker gains physical access to unlocked device, they can read GPS data in memory *during* an active session
- Mitigation: Lock your device, use device encryption (enabled by default on modern Android/iOS)

**Device Fingerprinting**
- BLE MAC address can identify a device across sessions (BLE privacy randomization is OS-dependent)
- Mitigation: Use BLE privacy mode (available on Android 6.0+, iOS 14+)

**Timing Side-Channels**
- Bearing/distance calculations may leak information via processing latency
- Mitigation: Not addressed in MVP (future: constant-time arithmetic)

**Radio Eavesdropping**
- BLE traffic is encrypted but peer discovery (advertising) is unencrypted
- Attacker can see *that* a session exists, but not contents or participants' locations
- Mitigation: Session ID is ephemeral; QR codes are only shown in-person

---

## Threat Model (STRIDE)

| Threat | Description | Mitigation |
|--------|-------------|-----------|
| **Spoofing** | Attacker impersonates a peer | Noise XX mutual authentication; ephemeral keys per handshake |
| **Tampering** | Attacker modifies messages in transit | AEAD encryption (Noise XX); MAC prevents forgery |
| **Repudiation** | Peer denies sending a location update | Nonce + timestamp validation; locally logged only |
| **Information Disclosure** | Attacker reads plaintext location | End-to-end encryption; Laplace noise obfuscation |
| **Denial of Service** | Attacker floods peers with messages | Rate limiting (2 updates/sec per peer); session size cap (20 peers) |
| **Elevation of Privilege** | Attacker gains unauthorized access to peers | No persistent credentials; ephemeral session tokens |

---

## Privacy Guarantees

### Geo-Indistinguishability

EchoPin implements **planar Laplace mechanism** (Andres et al., 2013) for location obfuscation:

p(z | x) ∝ e^(−ε·d(x,z))

where:
- `x` = true location
- `z` = noised location
- `ε` = privacy budget (0.5 by default)
- `d(x,z)` = Haversine distance

**At ε=0.5:**
- Expected noise radius: ~4 metres
- 95th percentile: ~50 metres
- 99th percentile: ~100 metres

**Trade-off:** Lower `ε` = more privacy but less accuracy. Users can adjust via settings.

### Differential Privacy

The Laplace mechanism provides **ε-differential privacy**, meaning:
- An attacker observing the noised location cannot distinguish between true locations within `2/ε` metres
- True position is **plausibly deniable** within the noise radius

---

## Vulnerability Disclosure

### Responsible Disclosure

If you discover a security vulnerability, **please report it responsibly:**

1. **Do NOT open a public GitHub issue** (this discloses the vulnerability)
2. **Email directly:** [402307375@my.richfield.ac.za](mailto:402307375@my.richfield.ac.za)
3. **Include:**
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if applicable)

### Response Timeline

- **Within 24 hours:** Acknowledge receipt
- **Within 7 days:** Initial assessment and security patch
- **Within 14 days:** Public disclosure (after patch release)

---

## Security Checklist

### For Users

- Keep device software updated (Android/iOS patches)
- Use device lock (PIN, biometric)
- Enable full-disk encryption (default on modern devices)
- Only join sessions with people you trust
- Review peer list before accepting location shares

### For Developers

- Run `flutter analyze` on all PRs
- Write tests for crypto operations
- Audit Noise handshake implementation
- Use `cryptography` package only (no roll-your-own crypto)
- Never log sensitive data (keys, GPS coordinates)

### For Deployments

- Use official Flutter SDK (from flutter.dev)
- Verify cryptographic libraries match pubspec.lock
- Test on multiple devices before release
- Include privacy notice in app store listings

---

## Known Limitations

### Current MVP (v0.1.0)

1. **BLE Privacy:** Depends on OS-level MAC randomization (not guaranteed)
2. **Constant-Time Crypto:** Not implemented; timing may leak information
3. **Rate Limiting:** Per-peer token bucket (not network-wide)
4. **Session Persistence:** Session memory is not cleared if app crashes
5. **Heartbeat Messages:** Implicit privacy leak if heartbeat timing is observable

### Planned Mitigations (Beta)

- [ ] Implement constant-time distance calculations
- [ ] Add explicit heartbeat padding (cover-traffic)
- [ ] Integrate OS-level BLE privacy APIs
- [ ] Formal security audit by third party

---

## Testing & Auditing

### Unit Tests

```bash
flutter test test/unit/location_engine_test.dart  # Noise generation
flutter test test/unit/mesh_service_test.dart     # Message validation
```

### Integration Tests

```bash
flutter test integration_test/                    # Full session lifecycle
```

### Manual Audit Checklist

- [ ] Verify no absolute GPS coordinates in network traffic
- [ ] Confirm Noise XX handshake completes successfully
- [ ] Check that keys are cleared on session exit
- [ ] Validate rate limiting (>2 msgs/sec = dropped)
- [ ] Test replay protection (duplicate nonces = dropped)

---

## References

- [Noise Protocol Framework](https://noiseprotocol.org/)
- [Geo-Indistinguishability (Andres et al., 2013)](https://arxiv.org/abs/1212.1984)
- [OWASP Mobile Security Testing Guide](https://owasp.org/www-project-mobile-security-testing-guide/)
- [Flutter Security Best Practices](https://flutter.dev/docs/testing/best-practices)

---

## Contact

**Security Questions?** Email: [402307375@my.richfield.ac.za](mailto:402307375@my.richfield.ac.za)