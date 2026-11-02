import 'package:echo_pin/models/session.dart';

/// A single BLE observation of a remote peer.
class BlePeerEvent {
  const BlePeerEvent({
    required this.peerId,
    required this.displayName,
    required this.distanceMeters,
    required this.rssi,
    required this.lastSeen,
  });

  final String peerId;
  final String displayName;
  final double distanceMeters;
  final int rssi;
  final DateTime lastSeen;
}

/// Platform boundary for BLE.
///
/// Implementations bridge to Kotlin (`BleBridgePlugin.kt`) and Swift
/// (`BleBridgePlugin.swift`) via method/event channels. Every method is
/// fail-safe: on unsupported platforms (web, Linux without a bridge) they
/// return `false`/no-op rather than throwing.
abstract class PlatformBleBridge {
  Stream<BlePeerEvent> get peerEvents;
  Future<bool> isAvailable();
  Future<bool> start({
    required String sessionId,
    required String peerId,
    required String displayName,
  });
  Future<void> stop();
  Future<void> injectPeer(PeerPresence peer);
  Future<void> dispose();
}
