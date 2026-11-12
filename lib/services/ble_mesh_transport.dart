import 'dart:async';

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:flutter/foundation.dart';

/// Bluetooth LE as a [MessageTransport], plus RSSI presence.
///
/// - Advertisements give *distance*: each sighting becomes a
///   [PeerPresence] on [peerUpdates], pruned after [staleTimeout].
/// - GATT writes carry *messages*: encrypted frames on [frames].
///
/// Survives the radio going away: when Bluetooth is off or permission is
/// missing, [status] is `waiting` with a precise problem, and the transport
/// restarts itself the moment the adapter reports `on`.
class BleMeshTransport implements MessageTransport {
  BleMeshTransport({
    required PlatformBleBridge bridge,
    this.displayName = 'EchoPin',
    Future<bool> Function()? ensurePermission,
    this.staleTimeout = const Duration(seconds: 15),
    this.pruneInterval = const Duration(seconds: 3),
  }) : _bridge = bridge,
       _ensurePermission = ensurePermission;

  final PlatformBleBridge _bridge;
  final String displayName;
  final Future<bool> Function()? _ensurePermission;
  final Duration staleTimeout;
  final Duration pruneInterval;

  final StreamController<List<PeerPresence>> _sightings =
      StreamController<List<PeerPresence>>.broadcast();
  final StreamController<TransportFrame> _frames =
      StreamController<TransportFrame>.broadcast();
  final StreamController<TransportStatus> _statusChanges =
      StreamController<TransportStatus>.broadcast();
  final Map<String, PeerPresence> _peers = <String, PeerPresence>{};
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  String? _sessionId;
  String? _peerId;
  Timer? _pruner;
  bool _radioUp = false;
  bool _starting = false;
  bool _closed = false;
  TransportStatus _status = TransportStatus.idle;

  /// Advertisement-based presence (distance only; see README "BLE protocol").
  Stream<List<PeerPresence>> get peerUpdates => _sightings.stream;
  bool get isStreaming => _radioUp;
  PlatformBleBridge get bridge => _bridge;

  @override
  PeerLink get link => PeerLink.ble;

  @override
  String get label => 'Bluetooth';

  @override
  TransportStatus get status => _status;

  @override
  Stream<TransportStatus> get statusChanges => _statusChanges.stream;

  @override
  Stream<TransportFrame> get frames => _frames.stream;

  @override
  Set<String> get reachablePeers => Set<String>.unmodifiable(_peers.keys);

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
  }) async {
    if (_closed) return false;
    _sessionId = sessionId;
    _peerId = peerId;
    if (_subs.isEmpty) {
      _subs
        ..add(_bridge.adapterStates.listen(_onAdapter))
        ..add(_bridge.peerEvents.listen(_onSighting, onError: (Object _) {}))
        ..add(
          _bridge.frames.listen((Uint8List data) {
            if (_radioUp && !_frames.isClosed) {
              _frames.add(TransportFrame(data, PeerLink.ble));
            }
          }, onError: (Object _) {}),
        );
    }
    await _tryStart();
    return _status.health != TransportHealth.unsupported;
  }

  /// Re-checks permission and adapter, e.g. after the person tapped "Allow"
  /// or came back from Settings.
  Future<void> retry() => _tryStart();

  /// Asks the OS to switch Bluetooth on (Android dialog; iOS power alert).
  Future<bool> requestEnable() => _bridge.requestEnable();

  Future<void> _tryStart() async {
    if (_closed || _starting || _radioUp) return;
    final String? sid = _sessionId;
    final String? pid = _peerId;
    if (sid == null || pid == null) return;
    _starting = true;
    try {
      final Future<bool> Function()? ask = _ensurePermission;
      if (ask != null && !await ask()) {
        _setStatus(
          const TransportStatus(
            TransportHealth.waiting,
            problem: PermissionDeniedError(PermissionKind.bluetooth),
          ),
        );
        return;
      }
      final BleAdapterState state = await _bridge.adapterState();
      switch (state) {
        case BleAdapterState.unsupported:
          _setStatus(
            const TransportStatus(
              TransportHealth.unsupported,
              problem: RadioUnavailableError(
                RadioKind.bluetooth,
                RadioProblem.unsupported,
              ),
            ),
          );
          return;
        case BleAdapterState.unauthorized:
          _setStatus(
            const TransportStatus(
              TransportHealth.waiting,
              problem: PermissionDeniedError(PermissionKind.bluetooth),
            ),
          );
          return;
        case BleAdapterState.off:
          _setStatus(
            const TransportStatus(
              TransportHealth.waiting,
              problem: RadioUnavailableError(
                RadioKind.bluetooth,
                RadioProblem.off,
              ),
            ),
          );
          return;
        case BleAdapterState.on:
        case BleAdapterState.unknown:
          break;
      }
      final bool ok = await _bridge.start(
        sessionId: sid,
        peerId: pid,
        displayName: displayName,
      );
      if (_closed) return;
      if (!ok) {
        _setStatus(
          const TransportStatus(
            TransportHealth.waiting,
            problem: TransportError('Bluetooth', 'could not start the radio'),
          ),
        );
        return;
      }
      _radioUp = true;
      _pruner ??= Timer.periodic(pruneInterval, (_) => _prune());
      _setStatus(
        TransportStatus(TransportHealth.running, reachable: _peers.length),
      );
    } catch (e) {
      _setStatus(
        TransportStatus(
          TransportHealth.failed,
          problem: TransportError('Bluetooth', '$e'),
        ),
      );
    } finally {
      _starting = false;
    }
  }

  void _onAdapter(BleAdapterState state) {
    if (_closed) return;
    if (state == BleAdapterState.on) {
      if (!_radioUp) unawaited(_tryStart());
      return;
    }
    // iOS reports `unknown` while CoreBluetooth initialises; not a change.
    if (state == BleAdapterState.unknown) return;
    // Radio went away: everything seen over it is no longer current.
    _radioUp = false;
    if (_peers.isNotEmpty) {
      _peers.clear();
      _emit();
    }
    _setStatus(
      TransportStatus(
        TransportHealth.waiting,
        problem: state == BleAdapterState.unauthorized
            ? const PermissionDeniedError(PermissionKind.bluetooth)
            : const RadioUnavailableError(
                RadioKind.bluetooth,
                RadioProblem.off,
              ),
      ),
    );
  }

  void _onSighting(BlePeerEvent event) {
    if (!_radioUp || event.peerId == _peerId) return; // never show self
    _peers[event.peerId] = PeerPresence(
      id: event.peerId,
      label: event.displayName,
      bearingDegrees: stableBearing(event.peerId),
      hasBearing: false, // RSSI has no direction; see PeerPresence.hasBearing
      distanceMeters: event.distanceMeters,
      lastSeen: event.lastSeen,
    );
    _emit();
  }

  /// BLE gives distance only. This is a placeholder angle derived from the
  /// peer id so a value always exists; it is NOT a direction, and the radar
  /// ignores it for peers with `hasBearing == false`.
  static double stableBearing(String id) {
    int h = 0;
    for (final int c in id.codeUnits) {
      h = (h * 31 + c) % 360;
    }
    return h.toDouble();
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
    if (!_sightings.isClosed) {
      _sightings.add(List<PeerPresence>.unmodifiable(_peers.values.toList()));
    }
    if (_radioUp) {
      _setStatus(
        TransportStatus(TransportHealth.running, reachable: _peers.length),
      );
    }
  }

  void _setStatus(TransportStatus s) {
    if (s == _status) return;
    _status = s;
    if (!_statusChanges.isClosed) _statusChanges.add(s);
  }

  @override
  Future<int> send(
    Uint8List frame, {
    Set<String> to = const <String>{},
    SendUrgency urgency = SendUrgency.normal,
  }) async {
    if (!_radioUp) return 0;
    try {
      return await _bridge.send(
        frame,
        to: to,
        announce: urgency == SendUrgency.announce,
      );
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _pruner?.cancel();
    _pruner = null;
    _radioUp = false;
    _peers.clear();
    _setStatus(TransportStatus.idle);
    try {
      await _bridge.stop();
    } catch (_) {} // best effort: shutting the radio down
    unawaited(_sightings.close());
    unawaited(_frames.close());
    unawaited(_statusChanges.close());
  }

  Future<void> dispose() => stop();
}
