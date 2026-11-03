import 'dart:async';
import 'dart:math';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:flutter/foundation.dart';

enum TransportMode { none, simulated, ble }

/// Owns the peer-presence stream. Can be driven by simulation (jitter) or by
/// a real [BleMeshTransport]. Session factories are transport-agnostic — the
/// caller decides which stream source to start.
class MeshService {
  MeshService({Random? random}) : _random = random ?? Random();

  final Random _random;
  final StreamController<List<PeerPresence>> _peerUpdates =
      StreamController<List<PeerPresence>>.broadcast();
  Timer? _ticker;
  BleMeshTransport? _bleTransport;
  StreamSubscription<List<PeerPresence>>? _bleSubscription;
  List<PeerPresence> _currentPeers = <PeerPresence>[];
  TransportMode _mode = TransportMode.none;

  Stream<List<PeerPresence>> get peerUpdates => _peerUpdates.stream;
  List<PeerPresence> get currentPeers =>
      List<PeerPresence>.unmodifiable(_currentPeers);
  bool get isStreaming => _mode != TransportMode.none;
  TransportMode get mode => _mode;

  Session createSession({
    required String id,
    required String name,
    double? boundaryRadiusMeters,
    List<PeerPresence>? initialPeers,
  }) {
    final List<PeerPresence> peers = initialPeers ?? _buildInitialPeers();
    _currentPeers = List<PeerPresence>.of(peers);
    return Session(
      id: id,
      name: name,
      boundaryRadiusMeters: boundaryRadiusMeters ?? 150,
      peers: List<PeerPresence>.of(peers),
    );
  }

  Session joinSession({
    required String sessionId,
    required String sessionName,
    double? boundaryRadiusMeters,
    List<PeerPresence>? initialPeers,
  }) {
    final List<PeerPresence> peers = initialPeers ?? _buildInitialPeers();
    _currentPeers = List<PeerPresence>.of(peers);
    return Session(
      id: sessionId,
      name: sessionName,
      boundaryRadiusMeters: boundaryRadiusMeters ?? 150,
      peers: List<PeerPresence>.of(peers),
    );
  }

  void startSimulated({Duration interval = const Duration(seconds: 2)}) {
    stopStreaming();
    _mode = TransportMode.simulated;
    _ticker = Timer.periodic(interval, (_) => _tick());
  }

  Future<bool> startBle({required BleMeshTransport transport}) async {
    stopStreaming();
    final bool ok = await transport.start();
    if (!ok) return false;
    _bleTransport = transport;
    _bleSubscription = transport.peerUpdates.listen((List<PeerPresence> peers) {
      _currentPeers = peers;
      if (!_peerUpdates.isClosed) _peerUpdates.add(peers);
    });
    _mode = TransportMode.ble;
    return true;
  }

  void stopStreaming() {
    _ticker?.cancel();
    _ticker = null;
    _bleSubscription?.cancel();
    _bleSubscription = null;
    _bleTransport?.stop();
    _bleTransport = null;
    _mode = TransportMode.none;
  }

  void _tick() {
    if (_currentPeers.isEmpty) return;
    _currentPeers = _currentPeers.map((PeerPresence p) {
      final double newDistance =
          (p.distanceMeters + (_random.nextDouble() - 0.5) * 50)
              .clamp(0.0, 500.0);
      final double rawBearing =
          p.bearingDegrees + (_random.nextDouble() - 0.5) * 20;
      final double newBearing =
          rawBearing < 0 ? rawBearing + 360 : rawBearing % 360;
      return p.copyWith(
        distanceMeters: newDistance,
        bearingDegrees: newBearing,
        lastSeen: DateTime.now(),
      );
    }).toList();
    if (!_peerUpdates.isClosed) {
      _peerUpdates.add(List<PeerPresence>.unmodifiable(_currentPeers));
    }
  }

  @visibleForTesting
  void simulatePeerUpdate(List<PeerPresence> peers) {
    _currentPeers = List<PeerPresence>.of(peers);
    if (!_peerUpdates.isClosed) {
      _peerUpdates.add(List<PeerPresence>.unmodifiable(_currentPeers));
    }
  }

  void dispose() {
    stopStreaming();
    _peerUpdates.close();
  }

  List<PeerPresence> _buildInitialPeers() {
    return <PeerPresence>[
      const PeerPresence(
        id: 'peer-a',
        label: 'Peer A',
        bearingDegrees: 30,
        distanceMeters: 68,
      ),
      const PeerPresence(
        id: 'peer-b',
        label: 'Peer B',
        bearingDegrees: 120,
        distanceMeters: 142,
      ),
      const PeerPresence(
        id: 'peer-c',
        label: 'Peer C',
        bearingDegrees: 200,
        distanceMeters: 254,
      ),
      const PeerPresence(
        id: 'peer-d',
        label: 'Peer D',
        bearingDegrees: 320,
        distanceMeters: 90,
      ),
    ];
  }
}
