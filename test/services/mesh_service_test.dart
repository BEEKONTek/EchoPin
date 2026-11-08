import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_ble_bridge.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  group('MeshService', () {
    test('starts in TransportMode.none', () {
      final MeshService m = MeshService();
      expect(m.mode, TransportMode.none);
      expect(m.isStreaming, isFalse);
      m.dispose();
    });

    test('startSimulated switches to simulated mode and ticks', () async {
      final MeshService m = MeshService();
      m.createSession(id: 'S', name: 'S');
      m.startSimulated(interval: const Duration(milliseconds: 10));
      expect(m.mode, TransportMode.simulated);
      final List<PeerPresence> tick = await m.peerUpdates.first;
      expect(tick, hasLength(4));
      m.dispose();
    });

    test('attachBle uses sightings without owning the radio', () async {
      final FakeBleBridge bridge = FakeBleBridge();
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      final MeshService m = MeshService();
      m.createSession(id: 'S', name: 'S', initialPeers: const <PeerPresence>[]);
      m.attachBle(t);
      expect(m.mode, TransportMode.ble);

      final Future<List<PeerPresence>> next = m.peerUpdates.first;
      bridge.emitSighting('PEERAAAA', 20);
      expect((await next).single.id, 'PEERAAAA');

      m.stopStreaming();
      expect(m.mode, TransportMode.none);
      expect(bridge.stopCalls, 0, reason: 'detaching never stops the radio');
      m.dispose();
      await t.stop();
      await bridge.dispose();
    });
  });

  group('MeshService synthetic peers', () {
    const PeerPresence probe = PeerPresence(
      id: 'synthetic-1',
      label: 'Probe',
      bearingDegrees: 10,
      distanceMeters: 30,
    );

    test('inject merges with base peers and emits', () async {
      final MeshService m = MeshService();
      m.createSession(id: 'S', name: 'S');
      final Future<List<PeerPresence>> next = m.peerUpdates.first;
      m.injectSyntheticPeer(probe);
      final List<PeerPresence> peers = await next;
      expect(peers.map((PeerPresence p) => p.id), contains('synthetic-1'));
      expect(peers.length, 5); // 4 demo peers + probe
      m.dispose();
    });

    test('synthetic peers survive BLE updates', () async {
      final FakeBleBridge bridge = FakeBleBridge();
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      final MeshService m = MeshService();
      m.createSession(id: 'S', name: 'S', initialPeers: const <PeerPresence>[]);
      m.attachBle(t);
      m.injectSyntheticPeer(probe);
      await _settle();
      final Future<List<PeerPresence>> next = m.peerUpdates.first;
      bridge.emitSighting('REMOTE01', 12);
      final List<PeerPresence> peers = await next;
      expect(peers.map((PeerPresence p) => p.id).toSet(), <String>{
        'REMOTE01',
        'synthetic-1',
      });
      m.dispose();
      await t.stop();
      await bridge.dispose();
    });

    test('new session clears synthetic peers', () {
      final MeshService m = MeshService();
      m.createSession(id: 'S', name: 'S');
      m.injectSyntheticPeer(probe);
      m.createSession(id: 'T', name: 'T');
      expect(m.syntheticPeerIds, isEmpty);
      m.dispose();
    });
  });
}
