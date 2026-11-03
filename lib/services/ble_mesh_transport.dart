import 'dart:async';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';

/// Adapts [PlatformBleBridge] event stream into a peer presence stream.
///
/// Owns RSSI-to-distance conversion, self-filtering, and stale-peer pruning.
/// Emits [List<PeerPresence>] so it composes with `SessionProvider` exactly
/// like the simulation does.
class BleMeshTransport {
  factory BleMeshTransport({
    required PlatformBleBridge bridge,
    required String sessionId,
    required String peerId,
    Duration staleTimeout = const Duration(seconds: 15),
    Duration pruneInterval = const Duration(seconds: 3),
  }) {
    return BleMeshTransport._(
      bridge,
      sessionId,
      peerId,
      staleTimeout,
      pruneInterval,
    );
  }

  BleMeshTransport._(
    this._bridge,
    this.sessionId,
    this.peerId,
    this.staleTimeout,
    this.pruneInterval,
  );

  final PlatformBleBridge _bridge;
  final String sessionId;
  final String peerId;
  final Duration staleTimeout;
  final Duration pruneInterval;

  final StreamController<List<PeerPresence>> _controller =
      StreamController<List<PeerPresence>>.broadcast();
  final Map<String, PeerPresence> _peers = <String, PeerPresence>{};
  StreamSubscription<BlePeerEvent>? _subscription;
  Timer? _pruner;
  bool _started = false;

  Stream<List<PeerPresence>> get peerUpdates => _controller.stream;
  bool get isStreaming => _started;

  Future<bool> start() async {
    if (_started) return true;
    final bool ok = await _bridge.start(
      sessionId: sessionId,
      peerId: peerId,
      displayName: 'EchoPin',
    );
    if (!ok) return false;
    _started = true;
    _subscription = _bridge.peerEvents.listen(
      _onEvent,
      onError: (Object error, StackTrace stack) {
        // Bridge already reports its own errors through its channel.
      },
    );
    _pruner = Timer.periodic(pruneInterval, (_) => _prune());
    return true;
  }

  void _onEvent(BlePeerEvent event) {
    if (event.peerId == peerId) return; // never show self
    _peers[event.peerId] = PeerPresence(
      id: event.peerId,
      label: event.displayName,
      bearingDegrees: _stableBearing(event.peerId),
      distanceMeters: event.distanceMeters,
      lastSeen: event.lastSeen,
    );
    _emit();
  }

  /// BLE gives distance only; derive a stable bearing from the peer id so the
  /// dot doesn't jump on every observation.
  double _stableBearing(String id) {
    return (id.hashCode % 360).abs().toDouble();
  }

  void _prune() {
    final DateTime now = DateTime.now();
    final int before = _peers.length;
    _peers.removeWhere((_, PeerPresence p) {
      final DateTime? seen = p.lastSeen;
      if (seen == null) return true; // unknown age — treat as stale
      return now.difference(seen) > staleTimeout;
    });
    if (_peers.length != before) _emit();
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(List<PeerPresence>.unmodifiable(_peers.values.toList()));
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _pruner?.cancel();
    _pruner = null;
    _started = false;
    await _bridge.stop();
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
