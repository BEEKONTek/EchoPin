import 'dart:async';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBridge implements PlatformBleBridge {
  final StreamController<BlePeerEvent> _events =
      StreamController<BlePeerEvent>.broadcast();
  bool startResult = true;

  @override
  Stream<BlePeerEvent> get peerEvents => _events.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
    required String displayName,
  }) async =>
      startResult;

  @override
  Future<void> stop() async {}

  @override
  Future<void> injectPeer(PeerPresence peer) async {}

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }

  void emit(BlePeerEvent e) => _events.add(e);
}

BlePeerEvent _ev(String peerId, double distance) => BlePeerEvent(
      peerId: peerId,
      displayName: 'Peer $peerId',
      distanceMeters: distance,
      rssi: -60,
      lastSeen: DateTime.now(),
    );

void main() {
  group('MeshService', () {
    test('starts in TransportMode.none', () {
      final MeshService m = MeshService();
      expect(m.mode, TransportMode.none);
      expect(m.isStreaming, isFalse);
      m.dispose();
    });

    test('startSimulated switches to simulated mode', () {
      final MeshService m = MeshService();
      m.createSession(id: 'ABCD1234', name: 'T');
      m.startSimulated();
      expect(m.mode, TransportMode.simulated);
      expect(m.isStreaming, isTrue);
      m.stopStreaming();
      expect(m.mode, TransportMode.none);
      m.dispose();
    });

    test('startBle returns false when transport refuses', () async {
      final _FakeBridge bridge = _FakeBridge()..startResult = false;
      final MeshService m = MeshService();
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        sessionId: 'ABCD1234',
        peerId: 'PEER0001',
      );
      final bool ok = await m.startBle(transport: t);
      expect(ok, isFalse);
      expect(m.mode, TransportMode.none);
      await t.dispose();
      m.dispose();
    });

    test('startBle emits PeerPresence from transport stream', () async {
      final _FakeBridge bridge = _FakeBridge();
      final MeshService m = MeshService();
      m.createSession(
          id: 'ABCD1234', name: 'T', initialPeers: const <PeerPresence>[]);
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        sessionId: 'ABCD1234',
        peerId: 'PEER0001',
      );

      final Completer<List<PeerPresence>> c =
          Completer<List<PeerPresence>>();
      m.peerUpdates.listen((List<PeerPresence> peers) {
        if (peers.isNotEmpty && !c.isCompleted) c.complete(peers);
      });

      final bool ok = await m.startBle(transport: t);
      expect(ok, isTrue);
      expect(m.mode, TransportMode.ble);

      bridge.emit(_ev('PEER0002', 42.0));
      final List<PeerPresence> result =
          await c.future.timeout(const Duration(seconds: 2));
      expect(result.single.id, 'PEER0002');
      await t.dispose();
      m.dispose();
    });

    test('stopStreaming returns mode to none', () async {
      final _FakeBridge bridge = _FakeBridge();
      final MeshService m = MeshService();
      m.createSession(
          id: 'ABCD1234', name: 'T', initialPeers: const <PeerPresence>[]);
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        sessionId: 'ABCD1234',
        peerId: 'PEER0001',
      );
      await m.startBle(transport: t);
      expect(m.mode, TransportMode.ble);
      m.stopStreaming();
      expect(m.mode, TransportMode.none);
      await t.dispose();
      m.dispose();
    });
  });
}
