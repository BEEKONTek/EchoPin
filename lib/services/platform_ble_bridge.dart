import 'package:echo_pin/models/session.dart';
import 'package:flutter/foundation.dart';

/// A single BLE observation of a remote peer's advertisement.
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

enum BleAdapterState {
  on,
  off,

  /// The app lacks Bluetooth permission.
  unauthorized,

  /// No BLE hardware, or no native bridge on this platform.
  unsupported,
  unknown;

  static BleAdapterState parse(Object? raw) {
    for (final BleAdapterState s in values) {
      if (s.name == raw) return s;
    }
    return BleAdapterState.unknown;
  }
}

/// Platform boundary for BLE.
///
/// Implemented natively by `BleBridgePlugin.kt` and `BleBridgePlugin.swift`.
/// Native code only advertises, scans (for RSSI distance), and moves opaque
/// encrypted frames over GATT; all cryptography stays in Dart. Every method
/// is fail-safe: unsupported platforms return false / no-op, never throw.
abstract class PlatformBleBridge {
  /// Advertisement sightings (distance from RSSI).
  Stream<BlePeerEvent> get peerEvents;

  /// Encrypted frames written to this device's GATT inbox.
  Stream<Uint8List> get frames;

  /// Adapter on/off/permission changes.
  Stream<BleAdapterState> get adapterStates;

  Future<bool> isAvailable();
  Future<BleAdapterState> adapterState();

  /// Asks the OS to turn Bluetooth on. Android shows a system dialog; iOS
  /// cannot, so this returns false and the UI explains where to go.
  Future<bool> requestEnable();

  Future<bool> start({
    required String sessionId,
    required String peerId,
    required String displayName,
  });

  /// Queues [data] for delivery over GATT to [to] (empty = every peer seen
  /// recently). [announce] lets native skip peers it announced to within
  /// the last minute. Returns how many peers it was queued for.
  Future<int> send(
    Uint8List data, {
    Set<String> to = const <String>{},
    bool announce = false,
  });

  Future<void> stop();
  Future<void> injectPeer(PeerPresence peer);
  Future<void> dispose();
}
