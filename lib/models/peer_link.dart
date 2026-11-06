/// How a peer is reachable.
enum PeerLink {
  /// Bluetooth LE (advertisements give distance; GATT carries messages).
  ble,

  /// Same Wi-Fi / hotspot (Bonjour + TCP). No distance.
  lan,

  /// In-memory simulation (demo mode and tests).
  loopback,

  /// Injected by an admin for testing.
  synthetic,
}
