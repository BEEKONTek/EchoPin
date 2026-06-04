# EchoPin Architecture

## System Overview
┌─────────────────────────────────────────────────────────────────────┐
│                    EchoPin Flutter App (UI Layer)                   │
├─────────────────────────────────────────────────────────────────────┤
│  HomeScreen (session creation)                                      │
│  SessionScreen (pinwheel display + peer list)                       │
│  PinwheelWidget (AnimatedBuilder + CustomPainter)                   │
└──────────────────────┬──────────────────────────────────────────────┘
│
┌───────────────┼───────────────┐
│               │               │
▼               ▼               ▼
┌────────────────┐ ┌──────────────┐ ┌──────────────┐
│  Session Model │ │State (Riverpod)
│ (ephemeral)    │ │(peers, bounds)│ │ UI State Mgmt │
└────────────────┘ └──────────────┘ └──────────────┘
│               │               │
└───────────────┼───────────────┘
│
┌───────────────┼───────────────┐
│               │               │
▼               ▼               ▼
┌─────────────────────────────────────────────────────────┐
│          Business Logic Layer (Services)               │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  LocationEngine          │         MeshService         │
│  ├─ GPS stream          │         ├─ BLE advertising   │
│  ├─ Compass heading     │         ├─ Peer discovery    │
│  ├─ Laplace noise       │         ├─ Noise handshake   │
│  ├─ Bearing compute     │         ├─ Message encrypt   │
│  ├─ Distance compute    │         ├─ Rate limiting     │
│  ├─ RSSI fallback       │         ├─ Replay protection │
│  └─ Dead-reckoning      │         └─ Multi-hop relay   │
│                          │                              │
│  EncryptionService (stub)                              │
│  └─ Noise XX protocol   │                              │
│                          │                              │
└─────────────────────────────────────────────────────────┘
│                               │
▼                               ▼
┌──────────────────────┐       ┌──────────────────────┐
│   Native Sensors     │       │   Native Radio       │
├──────────────────────┤       ├──────────────────────┤
│ ├─ GPS (Geolocator) │       │ ├─ BLE (flutter_blue)
│ ├─ Compass          │       │ ├─ Wi-Fi Direct      │
│ ├─ Accelerometer    │       │ └─ Mesh relay        │
│ └─ Gyroscope        │       └──────────────────────┘
└──────────────────────┘

---

## **Layered Architecture**

### **1. UI Layer**
- **HomeScreen:** Create/join session UI
- **SessionScreen:** Main pinwheel + peer list + boundary slider
- **PinwheelWidget:** CustomPainter canvas rendering with animation controller
- **PeerChip:** Compact peer status widget

**State Management:** Riverpod (lightweight, reactive)

---

### **2. Business Logic Layer**

#### **LocationEngine**
Responsible for computing **privacy-preserving relative location updates**.

**Key Methods:**
```dart
ObfuscatedLocation applyPlanarLaplaceNoise(Position rawPosition)
// Adds ε-differential privacy noise to GPS coordinates

double computeBearing(ObfuscatedLocation own, ObfuscatedLocation peer)
// Returns direction from own device to peer (0–360°)

double computeDistance(ObfuscatedLocation own, ObfuscatedLocation peer)
// Returns Haversine distance in metres

double estimateDistanceFromRssi({required int rssiDbm, ...})
// BLE signal strength fallback (when GPS unavailable)

RelativePresenceUpdate? buildPresenceUpdate({...})
// Constructs encrypted broadcast payload (bearing + distance only)
```

**Privacy Guarantee:**
- Raw GPS coordinates **never** leave `LocationEngine`
- Only **derived relative values** (bearing, distance) are transmitted
- Laplace noise ε=0.5 provides plausible deniability within ~50m

---

#### **MeshService**
Responsible for **peer discovery, encryption, and message relay**.

**Key Methods:**
```dart
Future<void> startAdvertising()
// BLE: advertise session UUID so peers can discover you

Stream<String> discoverPeers()
// BLE scan: find peers advertising the same session UUID

Future<bool> performHandshake(String peerAddress)
// Noise XX: mutual authentication, derive transport keys

void onRawMessageReceived(String fromAddress, Uint8List rawBytes)
// Validate, decrypt, rate-limit, and dispatch incoming messages

Future<void> broadcastPresence({required double bearingDeg, ...})
// Encrypt and send your presence update to all peers

Future<void> sendBye()
// Graceful session exit (notify peers before disconnect)
```

**Security Features:**
- **Noise XX encryption:** mutual authentication, forward secrecy
- **Rate limiting:** max 2 updates/peer/second (token bucket)
- **Replay protection:** nonce + timestamp validation
- **Session size cap:** max 20 peers to prevent DoS

---

#### **Session Model**
Holds **ephemeral session state** (never persisted).

**Key Properties:**
```dart
final String sessionId;            // 6-char human-readable code
final String qrPayload;            // Full join info (QR encoded)
final DateTime expiresAt;          // Auto-expire after 8 hours
final double boundaryRadiusM;      // User-configurable alert radius
final SessionKeys keys;            // Ephemeral crypto material
final Map<String, Peer> peers;     // All session peers
```

**Lifecycle:**
1. Created: `EchoSession.create(boundaryRadiusM: 200)`
2. Active: App advertises, discovers peers, broadcasts presence
3. Wiped: `session.wipe()` called unconditionally on exit → all data cleared

---

### **3. Data Models**

#### **Peer**
```dart
class Peer {
  final String peerId;              // Ephemeral anonymous token
  final String displayName;         // User-chosen nickname
  final String emoji;               // Visual label on pinwheel
  double relativeBearingDeg;        // 0–360° (North = 0)
  double relativeDistanceM;         // Metres
  bool outsideBoundary;             // Breach detection
  DateTime lastSeen;                // Stale data check (>10s = stale)
}
```

#### **ObfuscatedLocation**
```dart
class ObfuscatedLocation {
  final double latNoisedDeg;        // GPS + Laplace noise
  final double lonNoisedDeg;
  final double accuracyM;           // Error radius estimate
  final DateTime timestamp;
}
```

#### **RelativePresenceUpdate**
```dart
class RelativePresenceUpdate {
  final String fromPeerId;          // Sender's ephemeral token
  final double bearingDeg;          // Direction (0=N, 90=E, ...)
  final double distanceM;           // Metres (0–500m displayable)
  final int nonce;                  // Replay protection
}
```

---

### **4. Networking Stack**

#### **BLE Advertising & Discovery**
Device A (session host):
├─ startAdvertising()
│  └─ BLE service UUID = hash(sessionId)
│     └─ No localName, no device ID (privacy)
│
Device B (peer):
├─ discoverPeers()
│  └─ BLE scan for service UUID
│     └─ Found: Device A
│
Peers connect:
├─ performHandshake(Device_A_address)
│  └─ Noise XX (mutual auth)
│     └─ Derive transport keys
│
Ongoing:
├─ broadcastPresence()
│  └─ Encrypt: RelativePresenceUpdate
│     └─ Send via BLE characteristic write

#### **Noise XX Handshake** (Stub → Beta)
Pattern: XX (both parties authenticate)
Device A → Device B:  e, s
Device B → Device A:  e, ee, s, es
Device A → Device B:  se
After: both have:
├─ Shared secret (DH result)
├─ Transport keys (send + receive)
└─ Forward secrecy (ephemeral keys)

#### **Message Encryption** (Stub → Beta)
Plaintext: RelativePresenceUpdate (JSON)
├─ Serialize to JSON
├─ Encrypt with Noise transport key
├─ Prepend nonce + timestamp
└─ Send via BLE or Wi-Fi Direct

#### **Rate Limiting**
_RateLimiter (per peer):
├─ Max tokens: 5
├─ Refill: every 500ms
└─ Allow: consume 1 token per message
└─ Prevents DoS (max 2 msgs/sec per peer)

#### **Replay Protection**
_NonceCache (per peer):
├─ Track latest nonce received
├─ Reject: nonce ≤ latest nonce
├─ Reject: timestamp > 30 seconds old
└─ Accept: only strictly increasing nonces

---

### **5. Privacy Layer: Planar Laplace Noise**

**Mechanism:**
True location: x = (lat, lon)
Noised location: z = (lat + dLat, lon + dLon)
Noise radius r ~ Laplace(1/ε) in polar coordinates
Direction θ ~ Uniform[0, 2π)
ε = 0.5 (privacy budget):
├─ Expected noise: 2/ε = 4 metres
├─ 95th percentile: ~50 metres
└─ Plausible deniability within ~50m radius

**Code:**
```dart
double _sampleLaplaceRadius(double eps, double u) {
  final scale = 1.0 / eps;
  return -scale * (log(1 - u) + log(1 - (1 - u) * 0.5));
}
```

**Trade-off:**
- Lower ε → more privacy, more noise (less accurate)
- Higher ε → less privacy, less noise (more accurate)
- Default: ε=0.5 balances privacy ↔ usability

---

## **Data Flow Diagram**
┌──────────────────────────────────────────────────────────────┐
│                 Session Lifecycle                            │
└──────────────────────────────────────────────────────────────┘

CREATE SESSION
User ──[Create session]──> SessionScreen
├─ Session.create(boundaryRadiusM: 200)
├─ Generate ephemeral keys
├─ Start BLE advertising
├─ Start LocationEngine
└─ Show pinwheel + QR code
PEER JOINS (via QR scan)
Peer A ──[Show QR code]──> Peer B
Peer B ──[Scan QR]──> parse sessionId + publicKey
├─ Join same session
├─ Start BLE discovery
├─ Find Peer A (UUID match)
└─ Perform Noise XX handshake
PRESENCE UPDATES (continuous)
Peer A ──[Location update]──>
└─ LocationEngine
├─ Read GPS + compass
├─ Apply Laplace noise
├─ Compute bearing/distance TO Peer B
└─ Build RelativePresenceUpdate
└─ MeshService.broadcastPresence()
└─ Encrypt + send via BLE
│
Peer B ──[Receive encrypted update]──>
└─ MeshService.onRawMessageReceived()
├─ Decrypt
├─ Validate (rate limit, replay)
├─ Update Peer A's RelativePresenceUpdate
└─ Emit presenceUpdates stream
└─ SessionScreen rebuilds
└─ PinwheelWidget repaints
BOUNDARY BREACH DETECTION
Peer A ──[Moves beyond boundary]──>
└─ RelativePresenceUpdate.distanceM > boundaryRadiusM
├─ SessionScreen detects
├─ Emit _anyBreach = true
├─ Trigger haptic feedback
└─ Show red banner
SESSION EXIT
User ──[Leave session]──>
├─ MeshService.sendBye()
├─ MeshService.dispose()
├─ session.wipe() [CRITICAL]
│  ├─ peers.clear()
│  ├─ keys = null
│  └─ all data erased from memory
└─ Return to HomeScreen


---

## **File Organization**
lib/
├── main.dart                           # App entry, theme, routing
├── models/
│   ├── session.dart                    # EchoSession, Peer, SessionKeys
│   └── ...
├── services/
│   ├── location_engine.dart            # GPS + Laplace noise
│   ├── mesh_service.dart               # BLE + Noise XX
│   └── encryption_service.dart         # (stub)
├── screens/
│   ├── home_screen.dart                # Create/join session UI
│   └── session_screen.dart             # Pinwheel + peer list
└── widgets/
├── pinwheel_painter.dart           # CustomPainter (canvas rendering)
└── peer_chip.dart                  # Compact peer status widget
test/
├── unit/
│   ├── location_engine_test.dart       # Noise generation, bearing, distance
│   ├── session_test.dart               # Session creation, wipe
│   └── mesh_service_test.dart          # Rate limiting, replay protection
└── widget/
├── pinwheel_painter_test.dart      # Rendering, layout
└── home_screen_test.dart           # Navigation, session creation

---

## **Concurrency & Async Flow**

**Streams:**
```dart
// LocationEngine
Stream<Position> rawLocationStream  // GPS updates (3m+ distance filter)
Stream<double?> headingStream       // Compass heading updates

// MeshService
Stream<RelativePresenceUpdate> presenceUpdates  // Peer location updates
```

**Futures:**
```dart
// Session lifecycle
Future<EchoSession> EchoSession.create(...)
Future<void> MeshService.startAdvertising()
Future<bool> MeshService.performHandshake(...)
Future<void> MeshService.sendBye()
```

**State Management (Riverpod):**
```dart
// Example (not yet implemented):
final sessionProvider = StateNotifierProvider<SessionNotifier, EchoSession?>((ref) {
  return SessionNotifier();
});
```

---

## **Performance Considerations**

| Operation | Target | Strategy |
|-----------|--------|----------|
| Location update latency | <3 seconds E2E | BLE + direct relay; no cloud |
| Pinwheel redraw | 60 FPS | CustomPainter (no rebuild unless data changes) |
| Battery drain | <20% extra over 4h | 3m distance filter; adaptive broadcast rate |
| BLE range | ~100m | Direct range; future: multi-hop relay |
| Session size | 2–20 peers | Rate limiting prevents DoS; cap at 20 |

---

## **Known Limitations & Future Work**

| Limitation | Current | Planned (Beta) |
|-----------|---------|----------------|
| Encryption | Stub (pass-through) | Real Noise XX (dart_libp2p) |
| BLE discovery | Stub | Real flutter_blue_plus |
| Wi-Fi Direct | Not implemented | flutter_nearby_connections |
| Multi-hop relay | Stub | dart_libp2p protocol |
| UWB ranging | Not supported | Optional on API 31+ |
| IMU dead-reckoning | Linear only | Full accelerometer + gyroscope fusion |
| Smartwatch | Not implemented | Wear OS + watchOS companion |
| Constant-time crypto | Not implemented | Timing-safe distance calculations |

---

## **References**

- [Noise Protocol Framework](https://noiseprotocol.org/)
- [Geo-Indistinguishability (Andres et al., 2013)](https://arxiv.org/abs/1212.1984)
- [Flutter Architecture Guide](https://flutter.dev/docs/app-architecture)
- [Dart Async/Await](https://dart.dev/codelabs/async-await)