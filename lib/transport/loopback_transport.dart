import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:echo_pin/transport/message_transport.dart';

/// In-memory "radio" connecting [LoopbackTransport]s. Used by tests and by
/// demo mode, where simulated people run the real protocol stack.
class LoopbackHub {
  LoopbackHub({
    this.latency = const Duration(milliseconds: 30),
    this.dropRate = 0,
    math.Random? random,
  }) : _random = random ?? math.Random();

  Duration latency;

  /// Probability (0..1) that a frame is lost, to exercise retries.
  double dropRate;
  final math.Random _random;
  final Map<String, LoopbackTransport> _members = <String, LoopbackTransport>{};

  /// Peers that cannot currently hear each other: pair keys "a|b".
  final Set<String> _partitions = <String>{};

  void partition(String a, String b) => _partitions
    ..add('$a|$b')
    ..add('$b|$a');
  void heal(String a, String b) => _partitions
    ..remove('$a|$b')
    ..remove('$b|$a');

  Iterable<LoopbackTransport> _peersOf(LoopbackTransport t) =>
      _members.values.where(
        (LoopbackTransport o) =>
            o != t &&
            o._sessionId == t._sessionId &&
            !_partitions.contains('${t._peerId}|${o._peerId}'),
      );

  void _join(LoopbackTransport t) {
    _members[t._peerId!] = t;
    _refresh();
  }

  void _leave(LoopbackTransport t) {
    _members.remove(t._peerId);
    _refresh();
  }

  void _refresh() {
    for (final LoopbackTransport t in _members.values) {
      t._setReachable(_peersOf(t).map((LoopbackTransport o) => o._peerId!));
    }
  }

  int _deliver(LoopbackTransport from, Uint8List frame, Set<String> to) {
    int n = 0;
    for (final LoopbackTransport o in _peersOf(from)) {
      if (to.isNotEmpty && !to.contains(o._peerId)) continue;
      n++;
      if (dropRate > 0 && _random.nextDouble() < dropRate) continue;
      final Uint8List copy = Uint8List.fromList(frame);
      Timer(latency, () => o._receive(copy));
    }
    return n;
  }
}

class LoopbackTransport implements MessageTransport {
  LoopbackTransport(this.hub);

  final LoopbackHub hub;
  String? _sessionId;
  String? _peerId;
  TransportStatus _status = TransportStatus.idle;
  Set<String> _reachable = <String>{};
  final StreamController<TransportFrame> _frames =
      StreamController<TransportFrame>.broadcast();
  final StreamController<TransportStatus> _statusChanges =
      StreamController<TransportStatus>.broadcast();

  @override
  PeerLink get link => PeerLink.loopback;

  @override
  String get label => 'Simulation';

  @override
  TransportStatus get status => _status;

  @override
  Stream<TransportStatus> get statusChanges => _statusChanges.stream;

  @override
  Stream<TransportFrame> get frames => _frames.stream;

  @override
  Set<String> get reachablePeers => Set<String>.unmodifiable(_reachable);

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
  }) async {
    _sessionId = sessionId;
    _peerId = peerId;
    _setStatus(const TransportStatus(TransportHealth.running));
    hub._join(this);
    return true;
  }

  void _setReachable(Iterable<String> ids) {
    _reachable = ids.toSet();
    _setStatus(
      TransportStatus(TransportHealth.running, reachable: _reachable.length),
    );
  }

  void _setStatus(TransportStatus s) {
    if (s == _status) return;
    _status = s;
    if (!_statusChanges.isClosed) _statusChanges.add(s);
  }

  void _receive(Uint8List bytes) {
    if (_frames.isClosed || !_status.isUp) return;
    _frames.add(TransportFrame(bytes, PeerLink.loopback));
  }

  @override
  Future<int> send(
    Uint8List frame, {
    Set<String> to = const <String>{},
    SendUrgency urgency = SendUrgency.normal,
  }) async {
    if (!_status.isUp) return 0;
    return hub._deliver(this, frame, to);
  }

  @override
  Future<void> stop() async {
    if (_peerId != null) hub._leave(this);
    _setStatus(TransportStatus.idle);
    unawaited(_frames.close());
    unawaited(_statusChanges.close());
  }
}
