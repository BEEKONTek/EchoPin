import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:flutter/services.dart';

/// Bridges to the native BLE plugin on Android/iOS.
///
/// Channel names must match `BleBridgePlugin.kt` and `BleBridgePlugin.swift`
/// exactly.
class MethodChannelBleBridge implements PlatformBleBridge {
  static const MethodChannel _methods =
      MethodChannel('echo_pin/ble/methods');
  static const EventChannel _events = EventChannel('echo_pin/ble/events');

  Stream<BlePeerEvent>? _peerEvents;

  @override
  Stream<BlePeerEvent> get peerEvents {
    return _peerEvents ??= _events.receiveBroadcastStream().map(
      (dynamic raw) {
        final Map<String, dynamic> m =
            Map<String, dynamic>.from(raw as Map<dynamic, dynamic>);
        return BlePeerEvent(
          peerId: m['peerId'] as String,
          displayName: m['displayName'] as String,
          distanceMeters: (m['distanceMeters'] as num).toDouble(),
          rssi: (m['rssi'] as num).toInt(),
          lastSeen: DateTime.fromMillisecondsSinceEpoch(
            m['lastSeenMs'] as int,
          ),
        );
      },
    );
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final bool? ok = await _methods.invokeMethod<bool>('ping');
      return ok ?? false;
    } on MissingPluginException {
      return false;
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
      final bool? ok = await _methods.invokeMethod<bool>('start', <String, String>{
        'sessionId': sessionId,
        'peerId': peerId,
        'displayName': displayName,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {}
  }

  @override
  Future<void> injectPeer(PeerPresence peer) async {
    try {
      await _methods.invokeMethod<void>('inject', <String, dynamic>{
        'id': peer.id,
        'label': peer.label,
        'distanceMeters': peer.distanceMeters,
        'bearingDegrees': peer.bearingDegrees,
      });
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await stop();
    _peerEvents = null;
  }
}
