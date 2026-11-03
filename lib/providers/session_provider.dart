import 'dart:async';

import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/models/session_summary.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:echo_pin/services/ble_permission_service.dart';
import 'package:echo_pin/services/boundary_monitor.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:echo_pin/services/session_history_service.dart';
import 'package:flutter/foundation.dart';

class SessionProvider extends ChangeNotifier {
  factory SessionProvider({
    MeshService? meshService,
    SessionCodec? sessionCodec,
    SessionHistoryService? historyService,
    AlertProvider? alertProvider,
    PlatformBleBridge? bleBridge,
    BlePermissionService? permissionService,
  }) {
    return SessionProvider._(
      meshService ?? MeshService(),
      sessionCodec ?? SessionCodec(),
      historyService ?? SessionHistoryService(),
      alertProvider,
      bleBridge,
      permissionService ?? BlePermissionService(),
    );
  }

  SessionProvider._(
    this._meshService,
    this._sessionCodec,
    this._historyService,
    this._alertProvider,
    this._bleBridge,
    this._permissionService,
  ) {
    _peerSubscription = _meshService.peerUpdates.listen(_onPeersUpdated);
  }

  final MeshService _meshService;
  final SessionCodec _sessionCodec;
  final SessionHistoryService _historyService;
  final AlertProvider? _alertProvider;
  final PlatformBleBridge? _bleBridge;
  final BlePermissionService _permissionService;
  StreamSubscription<List<PeerPresence>>? _peerSubscription;

  Session? _session;
  List<SessionSummary> _history = <SessionSummary>[];

  Session? get session => _session;
  bool get hasSession => _session != null;
  MeshService get meshService => _meshService;
  SessionCodec get sessionCodec => _sessionCodec;
  TransportMode get transportMode => _meshService.mode;
  List<SessionSummary> get history =>
      List<SessionSummary>.unmodifiable(_history);

  Future<Session> createSession({
    required String name,
    double? boundaryRadiusMeters,
  }) async {
    final String id = _sessionCodec.generateId();
    final Session? bleSession = await _tryBle(id, name,
        sessionName: null, boundaryRadiusMeters: boundaryRadiusMeters);
    if (bleSession != null) return bleSession;
    return _startSimulated(id, name, null, boundaryRadiusMeters);
  }

  Future<Session> joinSession({
    required String sessionName,
    String? sessionId,
    double? boundaryRadiusMeters,
  }) async {
    final String id = sessionId ?? _sessionCodec.generateId();
    final Session? bleSession = await _tryBle(id, sessionName,
        sessionName: sessionName,
        boundaryRadiusMeters: boundaryRadiusMeters,
        isJoin: true);
    if (bleSession != null) return bleSession;
    return _startSimulated(id, sessionName, sessionName, boundaryRadiusMeters,
        isJoin: true);
  }

  Future<Session?> _tryBle(
    String id,
    String sessionLabel, {
    required String? sessionName,
    double? boundaryRadiusMeters,
    bool isJoin = false,
  }) async {
    if (_bleBridge == null) return null;
    final bool granted = await _permissionService.request();
    if (!granted) return null;

    // peerId is DISTINCT from sessionId so both devices advertise different
    // 16-byte payloads; otherwise each filters the other as "self".
    final String myPeerId = _sessionCodec.generateId();
    final Session session = isJoin
        ? _meshService.joinSession(
            sessionId: id,
            sessionName: sessionLabel,
            boundaryRadiusMeters: boundaryRadiusMeters,
            initialPeers: const <PeerPresence>[],
          )
        : _meshService.createSession(
            id: id,
            name: sessionLabel,
            boundaryRadiusMeters: boundaryRadiusMeters,
            initialPeers: const <PeerPresence>[],
          );

    final BleMeshTransport transport = BleMeshTransport(
      bridge: _bleBridge,
      sessionId: id,
      peerId: myPeerId,
    );
    final bool ok = await _meshService.startBle(transport: transport);
    if (!ok) {
      await transport.dispose();
      return null;
    }

    _session = session;
    notifyListeners();
    await _recordHistory(session);
    return session;
  }

  Future<Session> _startSimulated(
    String id,
    String sessionLabel,
    String? sessionName,
    double? boundaryRadiusMeters, {
    bool isJoin = false,
  }) async {
    final Session session = isJoin
        ? _meshService.joinSession(
            sessionId: id,
            sessionName: sessionLabel,
            boundaryRadiusMeters: boundaryRadiusMeters,
          )
        : _meshService.createSession(
            id: id,
            name: sessionLabel,
            boundaryRadiusMeters: boundaryRadiusMeters,
          );
    _session = session;
    _meshService.startSimulated();
    notifyListeners();
    await _recordHistory(session);
    return session;
  }

  Future<void> _recordHistory(Session session) async {
    final SessionSummary summary = SessionSummary(
      id: session.id,
      name: session.name,
      code: _sessionCodec.encode(session.id),
      boundaryRadiusMeters: session.boundaryRadiusMeters,
      createdAt: session.createdAt,
      lastJoinedAt: DateTime.now(),
    );
    await _historyService.record(summary);
    _history = await _historyService.load();
    notifyListeners();
  }

  void _onPeersUpdated(List<PeerPresence> peers) {
    final Session? current = _session;
    if (current == null) return;

    final List<BoundaryAlert> crossings = computeCrossings(
      previous: current.peers,
      current: peers,
      boundaryRadiusMeters: current.boundaryRadiusMeters,
      now: DateTime.now(),
    );
    for (final BoundaryAlert crossing in crossings) {
      _alertProvider?.handleCrossing(crossing);
    }

    _session = current.copyWith(peers: peers);
    notifyListeners();
  }

  void updateSessionName(String name) {
    final Session? current = _session;
    if (current == null) return;
    _session = current.copyWith(name: name);
    notifyListeners();
  }

  void updateBoundaryRadius(double boundaryRadiusMeters) {
    final Session? current = _session;
    if (current == null) return;
    _session = current.copyWith(boundaryRadiusMeters: boundaryRadiusMeters);
    notifyListeners();
  }

  Future<void> loadHistory() async {
    _history = await _historyService.load();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await _historyService.clear();
    _history = <SessionSummary>[];
    notifyListeners();
  }

  void leaveSession() {
    _meshService.stopStreaming();
    _alertProvider?.dismissAll();
    _session = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _peerSubscription?.cancel();
    _meshService.dispose();
    super.dispose();
  }
}
