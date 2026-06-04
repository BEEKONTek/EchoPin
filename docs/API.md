# EchoPin API Reference

## Table of Contents

- [Session](#session)
- [LocationEngine](#locationengine)
- [MeshService](#meshservice)
- [Models](#models)

---

## Session

### `EchoSession`

Main session object. Created fresh per session, wiped completely on exit.

#### Constructor
```dart
EchoSession({
  required String sessionId,
  required String qrPayload,
  required DateTime createdAt,
  required DateTime expiresAt,
  required double boundaryRadiusM,
  required SessionKeys keys,
  required String ownPeerId,
  SessionStatus status = SessionStatus.joining,
  Map? peers,
})
```

#### Factory
```dart
// Create a new hosted session (you are the creator)
static Future create({
  double boundaryRadiusM = 200,
  Duration sessionDuration = const Duration(hours: 8),
  String ownDisplayName = 'Me',
  String ownEmoji = '📍',
}) async
```

#### Properties
```dart
String sessionId                 // 6-character code (e.g., "X7K2PQ")
String qrPayload                 // Full join info (QR-encoded)
DateTime createdAt              // Session start time
DateTime expiresAt              // Auto-expiry deadline
double boundaryRadiusM          // Alert radius in metres (50–5000m)
SessionKeys keys                // Ephemeral cryptographic keys
String ownPeerId                // This device's anonymous token
SessionStatus status            // inactive | joining | active | expired
Map peers         // All session peers (keyed by peerId)
```

#### Getters
```dart
bool get isExpired              // true if DateTime.now() > expiresAt
bool get isActive              // true if status == active && !isExpired
List get activePeers     // Peers with lastSeen <= 10 seconds ago
bool get anyPeerOutsideBoundary // true if any peer.distanceM > boundaryRadiusM
```

#### Methods
```dart
// Update or add a peer's relative position
void updatePeer(Peer updated)
// peers[updated.peerId] = updated with outsideBoundary recalculated

// Remove a peer who has left
void removePeer(String peerId)
// peers.remove(peerId)

// CRITICAL: wipe all session data from memory
void wipe()
// peers.clear(), status = inactive, keys nullified
// MUST be called unconditionally on session exit
```

#### Example
```dart
// Create a new session
final session = await EchoSession.create(boundaryRadiusM: 200);
print('Session ID: ${session.sessionId}');  // "X7K2PQ"
print('QR Payload: ${session.qrPayload}');

// Add a discovered peer
session.updatePeer(Peer(
  peerId: 'peer-123',
  displayName: 'Alice',
  emoji: '🧡',
));

// Check boundary breach
if (session.anyPeerOutsideBoundary) {
  print('Someone left the boundary!');
}

// Clean up (call on exit)
session.wipe();  // All data erased
```

---

## LocationEngine

### `LocationEngine`

Computes privacy-preserving relative location (bearing + distance) from raw GPS + compass.

#### Constructor
```dart
LocationEngine({
  double epsilon = 0.5,  // Privacy budget (lower = more noise)
})
```

#### Streams
```dart
Stream get rawLocationStream
// Geolocator position updates (3m+ distance filter)
// Emits: Position(latitude, longitude, accuracy, timestamp, ...)

Stream get headingStream
// FlutterCompass heading updates (degrees, 0 = North)
// Emits: double (0–360) or null (no lock)
```

#### Methods

##### **Privacy: Planar Laplace Noise**
```dart
// Apply ε-differential privacy noise to raw GPS coordinate
ObfuscatedLocation applyPlanarLaplaceNoise(Position rawPosition)

// Returns: ObfuscatedLocation with noised lat/lon + accuracy estimate
// Noise radius: expected ~2/ε metres
// At ε=0.5: expected ~4m, 95th percentile ~50m
```

##### **Relative Position Computation**
```dart
// Compute bearing from own location to peer's location (0–360°)
double computeBearing(
  ObfuscatedLocation own,
  ObfuscatedLocation peer,
)
// Returns: double in [0, 360)
// 0° = North, 90° = East, 180° = South, 270° = West

// Compute Haversine distance between two noised locations
double computeDistance(
  ObfuscatedLocation own,
  ObfuscatedLocation peer,
)
// Returns: double in metres

// Estimate distance from BLE signal strength (RSSI)
double estimateDistanceFromRssi({
  required int rssiDbm,
  int txPowerDbm = -59,           // Calibration constant (device-specific)
  double pathLossExponent = 2.5,  // Free space (~2.0) to indoor (~4.0)
})
// Returns: distance in metres (or -1 if signal unreadable)
```

##### **Presence Update Builder**
```dart
// Build a privacy-preserving presence update to broadcast to peers
RelativePresenceUpdate? buildPresenceUpdate({
  required String ownPeerId,
  required ObfuscatedLocation ownLocation,
  required ObfuscatedLocation peerLocation,
})
// Returns: RelativePresenceUpdate (bearing + distance only)
//          or null if GPS is unavailable
```

##### **Dead-Reckoning (IMU fallback)**
```dart
// Estimate position using accelerometer + gyroscope during GPS gaps
ObfuscatedLocation? deadReckon({
  required ObfuscatedLocation lastKnown,
  required Duration elapsed,
  required double headingDeg,
  double estimatedSpeedMps = 1.2,  // Average walking speed
})
// Returns: projected position or null if insufficient IMU data
// Note: Stub in MVP; full integration planned for Beta
```

#### Example
```dart
final engine = LocationEngine(epsilon: 0.5);

// Listen to raw GPS
engine.rawLocationStream.listen((position) {
  print('Raw GPS: ${position.latitude}, ${position.longitude}');
});

// Listen to compass
engine.headingStream.listen((heading) {
  if (heading != null) {
    print('Compass: $heading°');
  }
});

// Apply noise to hide exact position
final obfuscated = engine.applyPlanarLaplaceNoise(rawPosition);
print('Noised: ${obfuscated.latNoisedDeg}, ${obfuscated.lonNoisedDeg}');

// Compute relative bearing to a peer
final bearing = engine.computeBearing(ownLocation, peerLocation);
print('Peer is at ${bearing}° (0=North)');

// Compute relative distance
final distance = engine.computeDistance(ownLocation, peerLocation);
print('Peer is ${distance.round()}m away');

// Build update to broadcast
final update = engine.buildPresenceUpdate(
  ownPeerId: 'me',
  ownLocation: obfuscated,
  peerLocation: peerObfuscated,
);
// update.bearingDeg, update.distanceM only (no GPS coords!)
```

---

## MeshService

### `MeshService`

Manages BLE peer discovery, Noise XX encryption, and message relay.

#### Constructor
```dart
MeshService({
  required EchoSession session,
})
```

#### Streams
```dart
Stream get presenceUpdates
// Emits validated, decrypted presence updates from peers
```

#### Methods

##### **BLE Advertising**
```dart
// Start advertising this device as a session participant
Future startAdvertising() async
// BLE service UUID = hash(sessionId)
// No localName or PII broadcast
// Ongoing until stopAdvertising() or dispose()

// Stop advertising
Future stopAdvertising() async
```

##### **Peer Discovery**
```dart
// Scan for peers advertising the session's service UUID
Stream discoverPeers() async*
// Yields: Bluetooth addresses of peers in the same session
// Used internally; typically called once per session
```

##### **Noise Handshake**
```dart
// Initiate Noise XX mutual authentication with a peer
Future performHandshake(String peerAddress) async
// Returns: true if handshake succeeded, false otherwise
// After success: all messages to/from this peer are encrypted
```

##### **Message Handling**
```dart
// Receive, validate, decrypt, and dispatch an incoming message
void onRawMessageReceived(String fromAddress, Uint8List rawBytes)
// Called by BLE GATT notification handler
// Performs:
//   1. Decryption (Noise transport keys)
//   2. Parsing (JSON deserialization)
//   3. Replay protection (nonce + timestamp validation)
//   4. Rate limiting (max 2 msgs/sec per peer)
//   5. Session size enforcement (max 20 peers)
//   6. Dispatch (emit presenceUpdates or handle bye/ping)
```

##### **Outbound Messages**
```dart
// Encrypt and broadcast your presence to all connected peers
Future broadcastPresence({
  required double bearingDeg,
  required double distanceM,
  required int nonce,
}) async
// Encrypts RelativePresenceUpdate and sends via BLE to each peer

// Send graceful session exit notification
Future sendBye() async
// Notify all peers you're leaving before disconnecting
// Call before session.wipe()
```

##### **Lifecycle**
```dart
// Clean up resources, close streams, send bye message
Future dispose() async
// Calls sendBye(), stopAdvertising(), closes controllers
// MUST be called to avoid resource leaks
```

#### Example
```dart
final mesh = MeshService(session: session);

// Start advertising
await mesh.startAdvertising();
print('Now discoverable as session ${session.sessionId}');

// Discover peers in background
mesh.discoverPeers().listen((address) {
  print('Found peer: $address');
  mesh.performHandshake(address).then((ok) {
    if (ok) print('Handshake complete with $address');
  });
});

// Listen for presence updates from peers
mesh.presenceUpdates.listen((update) {
  print('Peer ${update.fromPeerId} is at ${update.bearingDeg}°, ${update.distanceM}m away');
});

// Broadcast your position to peers
await mesh.broadcastPresence(
  bearingDeg: 45.0,
  distanceM: 120.0,
  nonce: 1,
);

// On exit
await mesh.sendBye();
await mesh.dispose();
```

---

## Models

### `Peer`

Represents a session peer's relative position and status.

```dart
class Peer {
  final String peerId;                // Ephemeral token (UUIDv4)
  final String displayName;           // User-chosen name
  final String emoji;                 // Visual emoji label
  
  double relativeBearingDeg;          // 0–360° (0=North)
  double relativeDistanceM;           // Metres
  bool outsideBoundary;               // Breach flag
  DateTime lastSeen;                  // Last update timestamp
  
  // Constructor
  Peer({
    required this.peerId,
    required this.displayName,
    required this.emoji,
    this.relativeBearingDeg = 0,
    this.relativeDistanceM = 0,
    this.outsideBoundary = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();
  
  // True if last update was >10 seconds ago
  bool get isStale => DateTime.now().difference(lastSeen).inSeconds > 10;
  
  // Return a new Peer with updated fields
  Peer copyWith({
    double? relativeBearingDeg,
    double? relativeDistanceM,
    bool? outsideBoundary,
    DateTime? lastSeen,
  }) => Peer(...);
}
```

### `ObfuscatedLocation`

Privacy-noised GPS coordinate + accuracy estimate.

```dart
class ObfuscatedLocation {
  final double latNoisedDeg;          // Noised latitude
  final double lonNoisedDeg;          // Noised longitude
  final double accuracyM;             // Error radius
  final DateTime timestamp;           // Sample time
  
  const ObfuscatedLocation({
    required this.latNoisedDeg,
    required this.lonNoisedDeg,
    required this.accuracyM,
    required this.timestamp,
  });
}
```

### `RelativePresenceUpdate`

Compact, encrypted payload broadcast to peers.

```dart
class RelativePresenceUpdate {
  final String fromPeerId;            // Sender's ephemeral token
  final double bearingDeg;            // Direction (0–360°)
  final double distanceM;             // Metres
  final int nonce;                    // Replay protection
  
  const RelativePresenceUpdate({
    required this.fromPeerId,
    required this.bearingDeg,
    required this.distanceM,
    required this.nonce,
  });
  
  // Serialize to JSON for transmission
  Map toJson() => {...};
  
  // Deserialize from JSON
  factory RelativePresenceUpdate.fromJson(Map json) => ...;
}
```

### `SessionKeys`

Ephemeral cryptographic material (never persisted).

```dart
class SessionKeys {
  final SimpleKeyPair identityKeyPair;    // Noise XX static key (X25519)
  final SimpleKeyPair ephemeralKeyPair;   // Per-session ephemeral key
  final Uint8List sessionSeed;            // 32-byte random seed
  
  const SessionKeys({
    required this.identityKeyPair,
    required this.ephemeralKeyPair,
    required this.sessionSeed,
  });
  
  // Generate fresh session keys
  static Future generate() async
}
```

---

## Enums

### `SessionStatus`
```dart
enum SessionStatus {
  inactive,    // Not in session
  joining,     // Advertising, discovering peers
  active,      // Broadcasting presence
  expired,     // Exceeded expiresAt deadline
}
```

### `MessageType`
```dart
enum MessageType {
  handshake,      // Noise XX initiation
  handshakeAck,   // Noise XX response
  presenceUpdate, // Encrypted location update
  ping,           // Keepalive / liveness check
  bye,            // Graceful departure
}
```

---

## Error Handling

All async operations may throw:

```dart
// LocationEngine
applyPlanarLaplaceNoise()  // Never throws (pure function)
computeBearing()           // Never throws (pure function)
computeDistance()          // Never throws (pure function)

// MeshService
startAdvertising()         // May throw PlatformException if BLE unavailable
discoverPeers()            // May throw PlatformException
performHandshake()         // Returns false if handshake fails
onRawMessageReceived()     // Catches and logs errors, doesn't throw
broadcastPresence()        // May throw if encryption fails (future)
dispose()                  // Never throws
```

---

## Best Practices

1. **Always call `session.wipe()` on exit** — data is sensitive
2. **Always call `mesh.dispose()`** — releases BLE resources
3. **Listen to `presenceUpdates` stream** — real-time location updates
4. **Check `peer.isStale`** — gray out old data in UI
5. **Validate privacy settings** — confirm ε=0.5 noise is enabled
6. **Test with 2+ devices** — BLE requires real devices (emulator limits)

---

## Migration Guide

No stable API yet (pre-release). All APIs may change before v1.0.

---