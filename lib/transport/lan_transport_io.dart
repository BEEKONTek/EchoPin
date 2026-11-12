import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/transport/message_transport.dart';

/// Wi-Fi / hotspot transport.
///
/// Each device listens on an ephemeral TCP port and advertises it over
/// Bonjour as `_echopin._tcp` with TXT `s=<sessionId> p=<peerId>`. Peers in
/// the same session connect and exchange length-prefixed frames.
///
/// Only public routing ids appear on the network; frames are already
/// encrypted and signed by the session layer, so a hostile LAN can at worst
/// drop or delay them. Links that die are re-dialled every [redialEvery].
class LanTransport implements MessageTransport {
  LanTransport({
    this.serviceType = '_echopin._tcp',
    this.redialEvery = const Duration(seconds: 8),
    this.connectTimeout = const Duration(seconds: 5),
  });

  static const bool isSupported = true;
  static const int maxFrame = 64 * 1024;
  static const List<int> _linkMagic = <int>[0x45, 0x50, 0x4C, 0x32]; // EPL2

  final String serviceType;
  final Duration redialEvery;
  final Duration connectTimeout;

  final StreamController<TransportFrame> _frames =
      StreamController<TransportFrame>.broadcast();
  final StreamController<TransportStatus> _statusChanges =
      StreamController<TransportStatus>.broadcast();
  final Map<String, List<_Link>> _links = <String, List<_Link>>{};
  final Map<String, _Endpoint> _endpoints = <String, _Endpoint>{};
  final Set<String> _dialling = <String>{};
  final Set<_Link> _pending = <_Link>{};

  String? _sessionId;
  String? _peerId;
  ServerSocket? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySub;
  StreamSubscription<Socket>? _serverSub;
  Timer? _redial;
  bool _closed = false;
  TransportStatus _status = TransportStatus.idle;

  @override
  PeerLink get link => PeerLink.lan;

  @override
  String get label => 'Wi-Fi';

  @override
  TransportStatus get status => _status;

  @override
  Stream<TransportStatus> get statusChanges => _statusChanges.stream;

  @override
  Stream<TransportFrame> get frames => _frames.stream;

  @override
  Set<String> get reachablePeers => <String>{
    for (final MapEntry<String, List<_Link>> e in _links.entries)
      if (e.value.isNotEmpty) e.key,
  };

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
  }) async {
    if (_closed) return false;
    _sessionId = sessionId;
    _peerId = peerId;
    try {
      _server = await _bind();
      _serverSub = _server!.listen(
        (Socket s) => _attach(s, expectedPeer: null),
        onError: (Object _) {},
      );
    } catch (e) {
      _setStatus(
        TransportStatus(
          TransportHealth.failed,
          problem: TransportError('Wi-Fi', 'could not open a port ($e)'),
        ),
      );
      return true; // Supported platform; may work after a restart.
    }

    try {
      final BonsoirService service = BonsoirService(
        name: 'echopin-$peerId',
        type: serviceType,
        port: _server!.port,
        attributes: <String, String>{'s': sessionId, 'p': peerId, 'v': '2'},
      );
      _broadcast = BonsoirBroadcast(service: service, printLogs: false);
      await _broadcast!.initialize();
      await _broadcast!.start();

      _discovery = BonsoirDiscovery(type: serviceType, printLogs: false);
      await _discovery!.initialize();
      _discoverySub = _discovery!.eventStream?.listen(
        _onDiscovery,
        onError: (Object _) {},
      );
      await _discovery!.start();
    } catch (e) {
      _setStatus(
        TransportStatus(
          TransportHealth.failed,
          problem: TransportError(
            'Wi-Fi',
            'local network discovery is unavailable ($e)',
          ),
        ),
      );
      return true;
    }

    _redial = Timer.periodic(redialEvery, (_) => _redialAll());
    _publishStatus();
    return true;
  }

  Future<ServerSocket> _bind() async {
    try {
      return await ServerSocket.bind(InternetAddress.anyIPv6, 0, v6Only: false);
    } catch (_) {
      return ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
  }

  // ── Discovery ──────────────────────────────────────────────────────────

  void _onDiscovery(BonsoirDiscoveryEvent event) {
    if (_closed) return;
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final BonsoirService service):
        // Android exposes TXT records only after resolution.
        final String? s = service.attributes['s'];
        if (s != null && s != _sessionId) return;
        if (service.attributes['p'] == _peerId) return;
        final BonsoirDiscovery? d = _discovery;
        if (d != null) {
          unawaited(_safely(() => service.resolve(d.serviceResolver)));
        }
      case BonsoirDiscoveryServiceResolvedEvent(:final BonsoirService service):
      case BonsoirDiscoveryServiceUpdatedEvent(:final BonsoirService service):
        _onResolved(service);
      case BonsoirDiscoveryServiceLostEvent(:final BonsoirService service):
        final String? p = service.attributes['p'];
        if (p != null) _endpoints.remove(p);
      default:
        break;
    }
  }

  void _onResolved(BonsoirService service) {
    final String? s = service.attributes['s'];
    final String? p = service.attributes['p'];
    if (s != _sessionId || p == null || p == _peerId || p.length != 8) return;
    final List<String> hosts = <String>[
      ...service.hostAddresses,
      if (service.hostname != null) service.hostname!,
    ];
    if (hosts.isEmpty || service.port <= 0) return;
    _endpoints[p] = _Endpoint(hosts, service.port);
    unawaited(_dial(p));
  }

  void _redialAll() {
    for (final String p in _endpoints.keys.toList()) {
      if ((_links[p] ?? const <_Link>[]).isEmpty) unawaited(_dial(p));
    }
  }

  Future<void> _dial(String peer) async {
    if (_closed || _dialling.contains(peer)) return;
    if ((_links[peer] ?? const <_Link>[]).isNotEmpty) return;
    final _Endpoint? ep = _endpoints[peer];
    if (ep == null) return;
    _dialling.add(peer);
    try {
      for (final String host in ep.hosts) {
        try {
          final Socket s = await Socket.connect(
            host,
            ep.port,
            timeout: connectTimeout,
          );
          if (_closed) {
            s.destroy();
            return;
          }
          _attach(s, expectedPeer: peer);
          return;
        } catch (_) {
          // Try the next address.
        }
      }
    } finally {
      _dialling.remove(peer);
    }
  }

  // ── Links ──────────────────────────────────────────────────────────────

  void _attach(Socket socket, {required String? expectedPeer}) {
    if (_closed) {
      socket.destroy();
      return;
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {} // best effort: a socket option, never fatal
    final _Link link = _Link(socket);
    _pending.add(link);
    // Write failures (e.g. EPIPE when the peer walked out of range) surface
    // on `done`, not at add(). Handle them here so they can never escape as
    // unhandled errors, and retire the link.
    unawaited(
      socket.done
          .then<void>((Object? _) {}, onError: (Object _) {})
          .whenComplete(() => _drop(link)),
    );
    // Introduce ourselves: magic + session id + peer id (routing only).
    _writeFrame(
      link,
      Uint8List.fromList(<int>[
        ..._linkMagic,
        ...ascii.encode(_sessionId!),
        ...ascii.encode(_peerId!),
      ]),
    );
    link.sub = socket.listen(
      (Uint8List data) => _onBytes(link, data, expectedPeer),
      onError: (Object _) => _drop(link),
      onDone: () => _drop(link),
      cancelOnError: true,
    );
    // A peer that never introduces itself is dropped.
    Timer(const Duration(seconds: 10), () {
      if (link.peerId == null) _drop(link);
    });
  }

  void _onBytes(_Link link, Uint8List data, String? expectedPeer) {
    link.buffer.add(data);
    while (true) {
      final Uint8List buf = link.buffer.toBytes();
      if (buf.length < 4) return;
      final int len = ByteData.sublistView(buf, 0, 4).getUint32(0);
      if (len == 0 || len > maxFrame) {
        _drop(link);
        return;
      }
      if (buf.length < 4 + len) return;
      final Uint8List frame = Uint8List.fromList(buf.sublist(4, 4 + len));
      link.buffer = BytesBuilder(copy: false)..add(buf.sublist(4 + len));

      if (link.peerId == null) {
        if (!_acceptIntro(link, frame, expectedPeer)) {
          _drop(link);
          return;
        }
        continue;
      }
      if (!_frames.isClosed) _frames.add(TransportFrame(frame, PeerLink.lan));
    }
  }

  bool _acceptIntro(_Link link, Uint8List frame, String? expectedPeer) {
    if (frame.length != 20) return false;
    for (int i = 0; i < 4; i++) {
      if (frame[i] != _linkMagic[i]) return false;
    }
    final String sid = ascii.decode(frame.sublist(4, 12), allowInvalid: true);
    final String pid = ascii.decode(frame.sublist(12, 20), allowInvalid: true);
    if (sid != _sessionId || pid == _peerId) return false;
    if (expectedPeer != null && pid != expectedPeer) return false;
    link.peerId = pid;
    _pending.remove(link);
    (_links[pid] ??= <_Link>[]).add(link);
    _publishStatus();
    return true;
  }

  void _drop(_Link link) {
    if (link.dropped) return;
    link.dropped = true;
    _pending.remove(link);
    final String? p = link.peerId;
    if (p != null) {
      _links[p]?.remove(link);
      if (_links[p]?.isEmpty ?? false) _links.remove(p);
    }
    unawaited(link.sub?.cancel());
    link.socket.destroy();
    if (!_closed) _publishStatus();
  }

  bool _writeFrame(_Link link, Uint8List frame) {
    try {
      final ByteData len = ByteData(4)..setUint32(0, frame.length);
      link.socket
        ..add(len.buffer.asUint8List())
        ..add(frame);
      return true;
    } catch (_) {
      _drop(link);
      return false;
    }
  }

  @override
  Future<int> send(
    Uint8List frame, {
    Set<String> to = const <String>{},
    SendUrgency urgency = SendUrgency.normal,
  }) async {
    if (_closed || frame.length > maxFrame) return 0;
    final Iterable<String> targets = to.isEmpty
        ? _links.keys.toList()
        : to.where(_links.containsKey);
    int n = 0;
    for (final String p in targets) {
      final List<_Link>? links = _links[p];
      if (links == null || links.isEmpty) continue;
      // Newest link first; fall back to older ones if a write fails.
      for (final _Link l in links.reversed.toList()) {
        if (_writeFrame(l, frame)) {
          n++;
          break;
        }
      }
    }
    return n;
  }

  void _publishStatus() {
    _setStatus(
      TransportStatus(
        TransportHealth.running,
        reachable: reachablePeers.length,
      ),
    );
  }

  void _setStatus(TransportStatus s) {
    if (s == _status) return;
    _status = s;
    if (!_statusChanges.isClosed) _statusChanges.add(s);
  }

  static Future<void> _safely(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {} // best effort: a socket option, never fatal
  }

  @override
  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    _redial?.cancel();
    await _safely(() async => _discoverySub?.cancel());
    await _safely(() async => _discovery?.stop());
    await _safely(() async => _broadcast?.stop());
    await _safely(() async => _serverSub?.cancel());
    await _safely(() async => _server?.close());
    for (final _Link l in <_Link>[
      ..._pending,
      for (final List<_Link> ls in _links.values) ...ls,
    ]) {
      unawaited(_safely(() async => l.sub?.cancel()));
      l.socket.destroy();
    }
    _links.clear();
    _pending.clear();
    _setStatus(TransportStatus.idle);
    unawaited(_frames.close());
    unawaited(_statusChanges.close());
  }
}

class _Link {
  _Link(this.socket);
  final Socket socket;
  String? peerId;
  bool dropped = false;
  StreamSubscription<Uint8List>? sub;
  BytesBuilder buffer = BytesBuilder(copy: false);
}

class _Endpoint {
  _Endpoint(this.hosts, this.port);
  final List<String> hosts;
  final int port;
}
