 EchoPin Threat Model & Privacy Analysis

## Executive Summary

EchoPin is designed with **privacy-first principles**: no servers, no accounts, no absolute location transmission. This document outlines threats we address, threats we accept, and privacy guarantees we provide.

---

## Implementation status (protocol v2)

How each attack below is handled in the shipped code. The wire format is
specified in `PROTOCOL.md`.

| Attack | Status in v2 |
| --- | --- |
| 1. Eavesdropping location | No coordinates exist anywhere. Distance is measured locally from RSSI; every message is XChaCha20-Poly1305 encrypted, including its type. |
| 2. Replay | Per-sender 64-message replay window plus a ±2 min timestamp check. Tested. |
| 3. Impersonation | Ed25519 signatures; sender id derived from the key and pinned on first use; a key change for a known id raises a security tray. Safety codes allow in-person verification. Tested. |
| 4. Flooding | Token bucket per sender (5, refill 1 / 500 ms), 20-member cap, 1 KiB body and 32-recipient limits, check-in cooldown. Tested. |
| 5. Timing inference | Not mitigated beyond privacy noise on displayed distances. |
| 6. BLE address tracking | The public session id and an 8-character per-session peer id are advertised. Peer ids are fresh per session, so devices are not linkable across sessions; within a session they are. |
| 7. GPS jamming | Not applicable: GPS is not used. |
| Spoofed BLE sightings | Unconfirmed sightings are shown as such, never trigger alerts, and cannot be pinged until a signed message proves identity. |
| Hostile names / notes | Control and bidi-override characters stripped, lengths capped. Tested. |
| Code leakage | Out of scope by design: whoever has the code is a member. No forward secrecy within a session (see `PROTOCOL.md` §8). |

## Central server (optional, v0.4)

When a deployment runs the EchoPin server (`docs/SERVER.md`), the
"no servers, no accounts" statement above no longer holds for that
deployment. Sessions still run phone to phone; the server adds accounts,
sealed session records, reports, diagnostics and backups.

| Threat | Mitigation | Residual risk |
| --- | --- | --- |
| Password guessing / stuffing | Argon2id (19 MiB, t=2); per-IP, per-email and per-device limits in PostgreSQL; lockout after 5 failures, doubling to 24 h; breached passwords refused; optional TOTP, required for staff | A stranger can pause *new-device* sign-ins for an email; the owner's own phones are unaffected |
| Account enumeration | Same answers and timing (600 ms floor, background mail) for every address; unknown emails lock like real ones; one generic code error | "Email unverified" shows only after a correct password |
| Stolen refresh token | Tokens bound to an Ed25519 device key; every refresh signed; rotation with family revocation on reuse (audited) | A fully compromised, unlocked phone can act as its owner until the device is removed |
| Phone identity spoofing | No IMEI / serial / advertising ids; device keys live in the OS keystore and never leave it | Platforms without a keystore fall back to app preferences |
| Database or backup leak | Only token hashes stored; TOTP secrets encrypted with a key outside the database; session records sealed to an escrow key outside the database; backups AES-256-GCM encrypted | Session metadata (names, times, counts, uploader accounts) is readable to anyone with database access |
| Insider reading session records | Break-glass only: staff role with two-step, written reason, grant and audit row committed before decryption, every admin emailed; optional custodian second seal means the server alone can't decrypt | Without a custodian key configured, whoever controls the server and its keys can decrypt; with one, they also need a responder's device |
| Fake uploads into a session | Session tag derived from the invite code; console flags non-members | A real member can upload junk under their own name |
| Tampering with the audit trail | HMAC chain over every row, keyed from `ECHOPIN_KEYS` (never in the database); UPDATE/DELETE/TRUNCATE refused by triggers; chain check in console and CLI; chain tip logged with every backup | Someone with the database *and* the keys can rewrite it; rows cut off the end leave a valid shorter chain (compare with the logged tip) |
| Account pre-hijacking | Confirming an email needs the code *and* the sign-up password, checked atomically | Someone can keep re-registering a pending address to annoy its owner (no access gained) |
| Spoofed client IPs | IP taken from an edge-overwritten header (`CLIENT_IP_HEADER`) or counted from the right of X-Forwarded-For | Wrong `TRUSTED_PROXY_HOPS` for a custom proxy setup lumps users together or reopens spoofing |
| Code guessing (email codes) | 8 digits, 5 guesses per code, at most 10 codes per account per day in the database | About 0.02 % a year against one account |
| Data kept too long | Daily retention job (records 365 d, diagnostics 90 d, closed reports 730 d) | The audit log is kept forever by design |
| Backup truncation / tampering | Per-frame authentication with index and final-frame flag; verify before restore; restore is CLI-only | Lost `keys/` means unrecoverable backups |
| Malicious uploads | Auth required; size limits; sealed-box structure and escrow key id checked; idempotent ids; reports cannot be filed below "high" for safety | A signed-in member can upload junk under their own name (attributable) |

Records never contain coordinates: the recorder stores events and each
member's last noisy, RSSI-based distance from the recording phone.

The full review of authentication and verification faults, with what was
fixed and what is accepted, is in `SECURITY_REVIEW.md`.

> **Note on the sections below.** They describe the original design
> (Noise XX handshakes, planar Laplace noise with an ε guarantee). The
> shipped protocol differs. Messages are XChaCha20-Poly1305 envelopes signed
> with per-session Ed25519 keys (`PROTOCOL.md`), and displayed distances get
> a bounded jitter that is fixed per person per minute. That jitter is a
> display nicety, not a differential-privacy guarantee. The tables above
> are authoritative.

## Threat Model Framework

### STRIDE Analysis

| Threat | Description | EchoPin Response | Residual Risk |
|--------|-------------|------------------|----------------|
| **Spoofing** | Attacker impersonates a peer | Noise XX mutual authentication; ephemeral keys per handshake | Low |
| **Tampering** | Attacker modifies messages in transit | AEAD encryption; MAC prevents forgery | Low |
| **Repudiation** | Peer denies sending a location update | Locally logged with nonce; no cloud record | Medium (local only) |
| **Information Disclosure** | Attacker reads plaintext location | E2E encryption + Laplace noise obfuscation | Low |
| **Denial of Service** | Attacker floods peers with messages | Rate limiting (2/sec per peer); session size cap (20) | Medium (DoS possible at BLE layer) |
| **Elevation of Privilege** | Attacker gains unauthorized access to peers | No persistent credentials; ephemeral tokens; no trusted third party | Low |

---

### LINDDUN Privacy Analysis

| Privacy Threat | Description | Mitigation | Residual Risk |
|---|---|---|---|
| **Linkability** | Attacker links multiple sessions to same device | BLE privacy mode (OS-dependent); ephemeral session IDs | Medium (BLE MAC address leakage possible) |
| **Identifiability** | Attacker identifies real-world person | No name, email, phone required; anonymous display names | Low |
| **Non-Repudiation** | User claims they weren't in a session | Local logs only; no third-party timestamp server | Medium (user dispute possible) |
| **Detectability** | Attacker detects that a session exists | BLE advertising is unencrypted; adversary sees UUID | Medium (can see session active, not participants) |
| **Disclosure of Information** | Attacker learns GPS coordinates | Laplace noise + relative bearing/distance only | Low |
| **Unawareness** | User unaware of location sharing | Clear UI; peer list visible; consent model| Low |
| **Non-Compliance** | System doesn't comply with privacy laws (GDPR, PIPEDA) | No data storage; ephemeral; user-controlled | Low |

---

## Attack Scenarios & Mitigations

### Attack 1: Eavesdropping GPS Coordinates

**Scenario:** Attacker intercepts network traffic to read exact coordinates.

**Mitigation:**
1. **No absolute GPS coordinates transmitted** — only bearing + distance
2. **Planar Laplace noise** — even if attacker somehow gets coordinates, they're noised
3. **E2E encryption** — Noise XX protects all messages

**Residual Risk:** **Low**

---

### Attack 2: Replay Attack

**Scenario:** Attacker captures an old presence update and replays it to make peers appear in old locations.

**Mitigation:**
1. **Nonce tracking** — each peer's nonce must be strictly increasing
2. **Timestamp validation** — updates older than 30 seconds rejected
3. **_NonceCache** — maintains latest nonce per peer

**Example:**
```dart
// Attacker tries to replay nonce=5 twice
Peer A sends update with nonce=5, timestamp=T
Peer B accepts (latest=5)
Attacker replays same message (nonce=5)
Peer B rejects (5 <= 5) Prevented
```

**Residual Risk:** **Low**

---

### Attack 3: Impersonation (Peer Spoofing)

**Scenario:** Attacker creates fake BLE device claiming to be peer in session.

**Mitigation:**
1. **Noise XX handshake** — requires both parties to prove ownership of private keys
2. **Mutual authentication** — XX pattern verifies both directions
3. **Ephemeral keys** — new keys per session, impossible to pre-compute

**Noise XX Flow:**
Device A ──→ e, s  ──→ Device B
Device A ←─ e, ee, s, es ←─ Device B
Device A ──→ se ──→ Device B
After handshake: both have confirmed shared secret; impersonation detected.

**Residual Risk:** **Low**

---

### Attack 4: Denial of Service (Message Flooding)

**Scenario:** Attacker sends thousands of fake location updates to overwhelm peers.

**Mitigation:**
1. **Rate limiting** — token bucket: 5 tokens per peer, 1 token per message, refill every 500ms → max 2 msgs/sec
2. **Session size cap** — max 20 peers; additional peers rejected with "session full"
3. **Bandwidth cap** — BLE MTU limits message size (~240 bytes)

**Token Bucket Example:**
```dart
// Attacker tries to send 10 messages in 1 second
for (int i = 0; i < 10; i++) {
  if (_rateLimiter.allow(peerId)) {  // Tokens: 5 → 4 → 3 → 2 → 1 → 0
    process_message();                // First 5 accepted
  } else {
    drop_message();                   // Messages 6–10 dropped
  }
}
```

**Residual Risk:** **Medium** (BLE layer DoS still possible; mitigated by kernel-level mechanisms)

---

### Attack 5: Location Inference via Timing

**Scenario:** Attacker observes when location updates arrive; infers movement patterns.

**Mitigation:**
1. **Partial:** GPS update filter (3m minimum movement) reduces inference window
2. **Partial:** Broadcast rate is visible to attacker
3. **Not addressed in MVP** — cover-traffic padding planned for future

**Residual Risk:** **Medium** (Addressed in Beta with constant-time crypto + padding)

---

### Attack 6: BLE MAC Address Tracking

**Scenario:** Attacker tracks BLE MAC address across sessions to link device identity.

**Mitigation:**
1. **BLE privacy mode** — randomize MAC per connection (OS-dependent, enabled on modern Android/iOS)
2. **Partial:** UUID in advertisement is session-specific (changes per session)

**Residual Risk:** **Medium** (Depends on OS implementation; user responsible for enabling privacy mode)

---

### Attack 7: GPS Jamming (Local)

**Scenario:** Attacker jams GPS signal to force reliance on BLE RSSI fallback (less accurate).

**Mitigation:**
1. **Graceful degradation** — fall back to BLE RSSI (less accurate, but functional)
2. **Dead-reckoning** — use IMU to maintain estimate during gaps
3. **User aware** — GPS loss causes accuracy decrease (user sees effect)

**Residual Risk:** **Medium** (Physical attack; hard to prevent; impact is reduced accuracy, not security)

---

## Privacy Guarantees

### Guarantee 1: No Absolute Coordinates Broadcast

**Claim:** Your true GPS coordinates **never** leave your device.

**Evidence:**
- LocationEngine computes relative bearing + distance from **noised** coordinates
- buildPresenceUpdate() returns only {bearingDeg, distanceM, nonce} — no lat/lon
- MeshService transmits only encrypted RelativePresenceUpdate payload

**Verification:**
```bash
# Capture network traffic; decrypt Noise frame; verify payload
# RelativePresenceUpdate JSON: {"b": 45.0, "d": 120.0, "n": 1}
# No "lat", "lon", "latitude", "longitude" fields present
```

---

### Guarantee 2: Planar Laplace Noise (ε-Differential Privacy)

**Claim:** Your location is obfuscated; true position is **plausibly deniable** within noise radius.

**Evidence:**
```dart
// Laplace mechanism at ε=0.5
Noise radius r ~ Laplace(1/ε = 2 metres)
Expected noise: 4 metres
95th percentile: ~50 metres
99th percentile: ~100 metres
```

**Mathematical Property:**
p(observed_noised_location | true_location_A)
─────────────────────────────────────────────── ≤ e^ε
p(observed_noised_location | true_location_B)
For ε=0.5: at most e^0.5 ≈ 1.65× more likely given location A vs. B

**Meaning:** Adversary cannot distinguish between true locations within ~50m; higher ε → more indistinguishable.

---

### Guarantee 3: End-to-End Encryption

**Claim:** Only peers with handshake keys can decrypt messages.

**Evidence:**
- Noise XX establishes shared secret (DH result)
- Transport keys derived via HKDF
- AEAD encryption (AES-256-GCM or ChaCha20-Poly1305)
- No key server; no key escrow

**Security:** No cloud provider, ISP, or man-in-the-middle can decrypt.

---

### Guarantee 4: Ephemeral & Volatile

**Claim:** No data persists; everything is wiped on session exit.

**Evidence:**
- SessionKeys generated fresh per session
- Keys never written to disk
- session.wipe() clears all peers, keys, timestamps
- Called unconditionally in dispose() method

**Verification:**
```bash
# After app exits, inspect device storage
# No .json files, no .db files, no cache containing coordinates
```

---

## Threat Acceptance (Known Limitations)

### 1. Local Device Compromise

**Threat:** If attacker gains physical/remote access to unlocked device, they can read GPS data in memory.

**Why We Accept It:** 
- No way to prevent with software alone
- User responsibility: lock device, use strong password
- Mitigation: device encryption (enabled by default)

**What We Could Do (Future):**
- Use secure enclave for key storage (hardware-backed)
- Wipe keys on screen lock
- Biometric auth for session join

---

### 2. BLE Layer DoS

**Threat:** Attacker floods BLE channel with junk packets, preventing peers from connecting.

**Why We Accept It:**
- BLE bandwidth is shared radio spectrum
- No way to authenticate at PHY layer
- Would require regulatory intervention

**What We Could Do (Future):**
- Use higher frequency bands (5.8 GHz Wi-Fi Direct)
- Implement channel hopping

---

### 3. Sybil Attack (Limited)

**Threat:** Attacker creates 20+ fake identities to fill session; blocks real peers.

**Why We Accept It (Partially Mitigated):**
- Session size cap at 20 peers
- Session join only via QR code (in-person, trusted)
- No way to join without knowing sessionId + publicKey

**Residual Risk:** **Low** (requires physical proximity + QR scan)

---

### 4. Physical Proximity Required for Join

**Threat:** Attacker must be within BLE range (~100m) + have QR code to join.

**Why We Accept It:**
- **Feature, not a bug!** Intended trust model
- Out-of-band join (QR) prevents online attackers
- In-person verification possible

**Residual Risk:** **Low** (attacker must be present)

---

## Testing & Validation

### Privacy Tests (Planned for Beta)

```dart
// Test 1: Verify no absolute coordinates in memory
void testNoAbsoluteCoordinatesInMemory() {
  final location = LocationEngine().applyPlanarLaplaceNoise(rawPos);
  final update = buildPresenceUpdate(...);
  
  final payload = jsonEncode(update);
  assert(!payload.contains(rawPos.latitude.toString())); 
  assert(!payload.contains(rawPos.longitude.toString()));
}

// Test 2: Verify Laplace noise distribution
void testLaplaceNoiseRadius() {
  final samples = List.generate(10000, (_) {
    final noised = engine.applyPlanarLaplaceNoise(knownPosition);
    return engine.computeDistance(
      ObfuscatedLocation(latNoisedDeg: knownPosition.latitude, ...),
      noised,
    );
  });
  
  final p95 = samples.sorted()[9500];
  assert(p95 < 60);  // 95th percentile < 60m
}

// Test 3: Replay protection
void testReplayProtection() {
  final msg = MeshMessage(nonce: 1, timestamp: now);
  assert(_nonceCache.isFresh('peer1', 1, now.ms)); 
  assert(!_nonceCache.isFresh('peer1', 1, now.ms)); // Rejected 
}
```

---

## Security Audit Checklist

- [ ] Code review of Noise XX handshake (cryptography expert)
- [ ] Review of Laplace noise implementation (statistician)
- [ ] Penetration testing (BLE, messages, key derivation)
- [ ] Memory safety audit (no buffer overflows, use-after-free)
- [ ] Dependency audit (all cryptography packages verified)
- [ ] Radio security review (BLE scanning privacy)

---

## Compliance

### GDPR (General Data Protection Regulation)

| Requirement | EchoPin Compliance |
|---|---|
| Explicit consent | User chooses to join session |
| Data minimization | Only relative bearing + distance |
| Storage limitation | No persistent storage; auto-wipe |
| User rights (access, delete) | No centralized data; nothing to access |
| Privacy by design | No servers, no accounts, no IDs |

**Status:** Compliant (no personal data collection)

---

### PIPEDA (Canada)

Similar to GDPR. Compliant.

---

### CCPA (California)

Applies to businesses collecting resident data. Likely exempt (not a business collecting data).

---

## Future Hardening

- [ ] Constant-time distance calculations (prevent timing side-channels)
- [ ] Cover-traffic padding (hide activity patterns)
- [ ] Secure enclave integration (hardware-backed keys)
- [ ] Formal privacy proof (academic verification)
- [ ] zk-SNARK location attestation (long-term research)

---

## Contact & Disclosure

**Found a vulnerability?** See [SECURITY.md](../SECURITY.md) for responsible disclosure process.

**Questions?** Email: 402307375@my.richfield.ac.za

---

*Last updated: June 2026*  
*Threat model version: 1.0 (Alpha)*