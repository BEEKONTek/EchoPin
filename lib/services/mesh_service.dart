import 'dart:async';
import 'dart:math';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:flutter/foundation.dart';

enum TransportMode { none, simulated, ble }

/// Owns the peer-presence stream. Can be driven by simulation (jitter) or by
/// a real [BleMeshTransport]. Session factories are transport-agnostic — the
/// caller decides which stream source to start.
///
/// Synthetic peers (admin test tooling) are kept separately and merged into
/// every emission regardless of transport, so they behave identically under
/// simulation and BLE.
class MeshService {
  MeshService({Random? random}) : _random = random ?? Random();

  final Random _random;
  final StreamController<List<PeerPresence>> _peerUpdates =
      StreamController<List<PeerPresence>>.broadcast();
  Timer? _ticker;
  BleMeshTransport? _bleTransport;
  StreamSubscription<List<PeerPresence>>? _bleSubscription;
  List<PeerPresence> _currentPeers = <PeerPresence>[];
  final Map<String, PeerPresence> _synthetic = <String, PeerPresence>{};
  TransportMode _mode = TransportMode.none;

  Stream<List<PeerPresence>> get peerUpdates => _peerUpdates.stream;
  List<PeerPresence> get currentPeers =>
      List<PeerPresence>.unmodifiable(_merged());
  bool get isStreaming => _mode != TransportMode.none;
  TransportMode get mode => _mode;
  Set<String> get syntheticPeerIds => Set<String>.unmodifiable(_synthetic.keys);
  List<PeerPresence> get syntheticPeers =>
      List<PeerPresence>.unmodifiable(_synthetic.values);

  Session createSession({
    required String id,
    required String name,
    double? boundaryRadiusMeters,
    List<PeerPresence>? initialPeers,
  }) {
    final List<PeerPresence> peers = initialPeers ?? _buildInitialPeers();
    _currentPeers = List<PeerPresence>.of(peers);
    _synthetic.clear();
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
    _synthetic.clear();
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

  /// Uses [transport]'s advertisement sightings as the presence source.
  ///
  /// The session engine owns the transport's lifecycle (start / stop);
  /// this only listens, so detaching never tears the radio down.
  void attachBle(BleMeshTransport transport) {
    stopStreaming();
    _bleTransport = transport;
    _bleSubscription = transport.peerUpdates.listen((List<PeerPresence> peers) {
      _currentPeers = peers;
      _emit();
    });
    _mode = TransportMode.ble;
  }

  BleMeshTransport? get bleTransport => _bleTransport;

  void stopStreaming() {
    _ticker?.cancel();
    _ticker = null;
    _bleSubscription?.cancel();
    _bleSubscription = null;
    _bleTransport = null;
    _mode = TransportMode.none;
  }

  /// Adds or replaces (same id) a synthetic peer and emits immediately.
  /// Re-injecting with a new distance is how admins drive a boundary
  /// crossing on demand.
  void injectSyntheticPeer(PeerPresence peer) {
    _synthetic[peer.id] = peer.copyWith(lastSeen: DateTime.now());
    _emit();
  }

  bool removeSyntheticPeer(String id) {
    final bool removed = _synthetic.remove(id) != null;
    if (removed) _emit();
    return removed;
  }

  void clearSyntheticPeers() {
    if (_synthetic.isEmpty) return;
    _synthetic.clear();
    _emit();
  }

  void _tick() {
    if (_currentPeers.isEmpty && _synthetic.isEmpty) return;
    _currentPeers = _currentPeers.map((PeerPresence p) {
      final double newDistance =
          (p.distanceMeters + (_random.nextDouble() - 0.5) * 8).clamp(
            2.0,
            120.0, // may drift just past the 100 m radar edge
          );
      final double rawBearing =
          p.bearingDegrees + (_random.nextDouble() - 0.5) * 20;
      final double newBearing = rawBearing < 0
          ? rawBearing + 360
          : rawBearing % 360;
      return p.copyWith(
        distanceMeters: newDistance,
        bearingDegrees: newBearing,
        lastSeen: DateTime.now(),
      );
    }).toList();
    _emit();
  }

  List<PeerPresence> _merged() => <PeerPresence>[
    ..._currentPeers.where((PeerPresence p) => !_synthetic.containsKey(p.id)),
    ..._synthetic.values,
  ];

  void _emit() {
    if (!_peerUpdates.isClosed) {
      _peerUpdates.add(List<PeerPresence>.unmodifiable(_merged()));
    }
  }

  @visibleForTesting
  void simulatePeerUpdate(List<PeerPresence> peers) {
    _currentPeers = List<PeerPresence>.of(peers);
    _emit();
  }

  void dispose() {
    stopStreaming();
    _peerUpdates.close();
  }

  List<PeerPresence> _buildInitialPeers() {
    return const <PeerPresence>[
      PeerPresence(
        id: 'peer-a',
        label: 'Peer A',
        bearingDegrees: 30,
        distanceMeters: 22,
      ),
      PeerPresence(
        id: 'peer-b',
        label: 'Peer B',
        bearingDegrees: 120,
        distanceMeters: 41,
      ),
      PeerPresence(
        id: 'peer-c',
        label: 'Peer C',
        bearingDegrees: 200,
        distanceMeters: 78,
      ),
      PeerPresence(
        id: 'peer-d',
        label: 'Peer D',
        bearingDegrees: 320,
        distanceMeters: 33,
      ),
    ];
  }
}
