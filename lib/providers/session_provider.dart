import 'dart:async';

import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/models/session_summary.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/services/boundary_monitor.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:echo_pin/services/session_history_service.dart';
import 'package:flutter/foundation.dart';

/// Owns the active session, listens for peer updates, and dispatches boundary
/// crossings to [AlertProvider].
///
/// A factory constructor is used so the private fields can be `final` while
/// keeping the public API named/optional. Named parameters cannot start with
/// an underscore, so the alternative would be a public field or an analyzer
/// ignore — this is the idiomatic Dart workaround.
class SessionProvider extends ChangeNotifier {
  factory SessionProvider({
    MeshService? meshService,
    SessionCodec? sessionCodec,
    SessionHistoryService? historyService,
    AlertProvider? alertProvider,
  }) {
    return SessionProvider._(
      meshService ?? MeshService(),
      sessionCodec ?? SessionCodec(),
      historyService ?? SessionHistoryService(),
      alertProvider,
    );
  }

  SessionProvider._(
    this._meshService,
    this._sessionCodec,
    this._historyService,
    this._alertProvider,
  ) {
    _peerSubscription = _meshService.peerUpdates.listen(_onPeersUpdated);
  }

  final MeshService _meshService;
  final SessionCodec _sessionCodec;
  final SessionHistoryService _historyService;
  final AlertProvider? _alertProvider;
  StreamSubscription<List<PeerPresence>>? _peerSubscription;

  Session? _session;
  List<SessionSummary> _history = <SessionSummary>[];

  Session? get session => _session;
  bool get hasSession => _session != null;
  MeshService get meshService => _meshService;
  SessionCodec get sessionCodec => _sessionCodec;
  List<SessionSummary> get history =>
      List<SessionSummary>.unmodifiable(_history);

  Future<Session> createSession({
    required String name,
    double? boundaryRadiusMeters,
  }) async {
    final String id = _sessionCodec.generateId();
    final Session session = _meshService.createSession(
      id: id,
      name: name,
      boundaryRadiusMeters: boundaryRadiusMeters,
    );
    _session = session;
    _meshService.startStreaming();
    notifyListeners();
    await _recordHistory(session);
    return session;
  }

  Future<Session> joinSession({
    required String sessionName,
    String? sessionId,
    double? boundaryRadiusMeters,
  }) async {
    final String id = sessionId ?? _sessionCodec.generateId();
    final Session session = _meshService.joinSession(
      sessionId: id,
      sessionName: sessionName,
      boundaryRadiusMeters: boundaryRadiusMeters,
    );
    _session = session;
    _meshService.startStreaming();
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
