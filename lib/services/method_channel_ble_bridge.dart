import 'dart:async';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:flutter/services.dart';

/// Bridges to the native BLE plugin on Android/iOS.
///
/// Channel names and event shapes must match `BleBridgePlugin.kt` and
/// `BleBridgePlugin.swift` exactly. One event channel carries three event
/// types, distinguished by `type`: `sighting`, `frame`, `adapter`.
class MethodChannelBleBridge implements PlatformBleBridge {
  static const MethodChannel _methods = MethodChannel('echo_pin/ble/methods');
  static const EventChannel _events = EventChannel('echo_pin/ble/events');

  Stream<Map<Object?, Object?>>? _raw;

  /// The platform stream is broadcast, so every filtered view below shares
  /// one native subscription.
  Stream<Map<Object?, Object?>> get _all => _raw ??= _events
      .receiveBroadcastStream()
      .where((dynamic e) => e is Map)
      .map((dynamic e) => e as Map<Object?, Object?>)
      .handleError((Object _) {}) // Native errors are reported as status.
      .asBroadcastStream();

  @override
  Stream<BlePeerEvent> get peerEvents => _all
      .where(
        (Map<Object?, Object?> m) => (m['type'] ?? 'sighting') == 'sighting',
      )
      .map((Map<Object?, Object?> m) {
        return BlePeerEvent(
          peerId: m['peerId']! as String,
          displayName: (m['displayName'] as String?) ?? 'Peer',
          distanceMeters: (m['distanceMeters']! as num).toDouble(),
          rssi: (m['rssi']! as num).toInt(),
          lastSeen: DateTime.fromMillisecondsSinceEpoch(
            (m['lastSeenMs']! as num).toInt(),
          ),
        );
      });

  @override
  Stream<Uint8List> get frames => _all
      .where((Map<Object?, Object?> m) => m['type'] == 'frame')
      .map((Map<Object?, Object?> m) => m['data'])
      .where((Object? d) => d is Uint8List)
      .cast<Uint8List>();

  @override
  Stream<BleAdapterState> get adapterStates => _all
      .where((Map<Object?, Object?> m) => m['type'] == 'adapter')
      .map((Map<Object?, Object?> m) => BleAdapterState.parse(m['state']));

  @override
  Future<bool> isAvailable() async {
    try {
      return await _methods.invokeMethod<bool>('ping') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<BleAdapterState> adapterState() async {
    try {
      return BleAdapterState.parse(
        await _methods.invokeMethod<String>('adapterState'),
      );
    } on MissingPluginException {
      return BleAdapterState.unsupported;
    } catch (_) {
      return BleAdapterState.unknown;
    }
  }

  @override
  Future<bool> requestEnable() async {
    try {
      return await _methods.invokeMethod<bool>('requestEnable') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
    required String displayName,
  }) async {
    try {
      return await _methods.invokeMethod<bool>('start', <String, String>{
            'sessionId': sessionId,
            'peerId': peerId,
            'displayName': displayName,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> send(
    Uint8List data, {
    Set<String> to = const <String>{},
    bool announce = false,
  }) async {
    try {
      return await _methods.invokeMethod<int>('send', <String, Object>{
            'data': data,
            'to': to.toList(),
            'announce': announce,
          }) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {}
  }

  @override
  Future<void> injectPeer(PeerPresence peer) async {}

  @override
  Future<void> dispose() async {
    await stop();
  }
}
