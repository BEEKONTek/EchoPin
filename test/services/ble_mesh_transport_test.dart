import 'dart:async';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBridge implements PlatformBleBridge {
  final StreamController<BlePeerEvent> _events =
      StreamController<BlePeerEvent>.broadcast();
  bool started = false;
  String? lastSessionId;
  String? lastPeerId;

  @override
  Stream<BlePeerEvent> get peerEvents => _events.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
    required String displayName,
  }) async {
    lastSessionId = sessionId;
    lastPeerId = peerId;
    started = true;
    return true;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  @override
  Future<void> injectPeer(PeerPresence peer) async {}

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }

  void emit(BlePeerEvent e) => _events.add(e);
}

class _DenyBridge implements PlatformBleBridge {
  @override
  Stream<BlePeerEvent> get peerEvents => const Stream<BlePeerEvent>.empty();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
    required String displayName,
  }) async =>
      false;

  @override
  Future<void> stop() async {}

  @override
  Future<void> injectPeer(PeerPresence peer) async {}

  @override
  Future<void> dispose() async {}
}

BlePeerEvent _event(String peerId, double distance) {
  return BlePeerEvent(
    peerId: peerId,
    displayName: 'Peer $peerId',
    distanceMeters: distance,
    rssi: -60,
    lastSeen: DateTime.now(),
  );
}

void main() {
  group('BleMeshTransport', () {
    test('start returns false when bridge refuses', () async {
      final _DenyBridge deny = _DenyBridge();
      final BleMeshTransport t = BleMeshTransport(
        bridge: deny,
        sessionId: 'ABCD1234',
        peerId: 'EFGH5678',
      );
      expect(await t.start(), isFalse);
      await t.dispose();
    });

    test('start passes session and peer ids to bridge', () async {
      final _FakeBridge bridge = _FakeBridge();
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        sessionId: 'ABCD1234',
        peerId: 'EFGH5678',
      );
      expect(await t.start(), isTrue);
      expect(bridge.started, isTrue);
      expect(bridge.lastSessionId, 'ABCD1234');
      expect(bridge.lastPeerId, 'EFGH5678');
      await t.dispose();
      await bridge.dispose();
    });

    test('emits PeerPresence when bridge emits BlePeerEvent', () async {
      final _FakeBridge bridge = _FakeBridge();
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        sessionId: 'ABCD1234',
        peerId: 'EFGH5678',
      );
      await t.start();

      final Completer<List<PeerPresence>> c =
          Completer<List<PeerPresence>>();
      t.peerUpdates.listen((List<PeerPresence> peers) {
        if (peers.isNotEmpty && !c.isCompleted) c.complete(peers);
      });

      bridge.emit(_event('PEER0001', 42.0));
      final List<PeerPresence> result =
          await c.future.timeout(const Duration(seconds: 2));
      expect(result.length, 1);
      expect(result.single.id, 'PEER0001');
      expect(result.single.distanceMeters, 42.0);
      expect(result.single.label, 'Peer PEER0001');
      await t.dispose();
      await bridge.dispose();
    });

    test('filters self out of emitted peer list', () async {
      final _FakeBridge bridge = _FakeBridge();
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        sessionId: 'ABCD1234',
        peerId: 'SELF0001',
      );
      await t.start();

      final Completer<List<PeerPresence>> c =
          Completer<List<PeerPresence>>();
      t.peerUpdates.listen((List<PeerPresence> peers) {
        if (peers.isNotEmpty && !c.isCompleted) c.complete(peers);
      });

      bridge.emit(_event('SELF0001', 5.0));
      bridge.emit(_event('PEER0001', 42.0));
      final List<PeerPresence> result =
          await c.future.timeout(const Duration(seconds: 2));
      expect(result.any((PeerPresence p) => p.id == 'SELF0001'), isFalse);
      expect(result.any((PeerPresence p) => p.id == 'PEER0001'), isTrue);
      await t.dispose();
      await bridge.dispose();
    });

    test('prunes peers not seen recently', () async {
      final _FakeBridge bridge = _FakeBridge();
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        sessionId: 'ABCD1234',
        peerId: 'EFGH5678',
        staleTimeout: const Duration(milliseconds: 100),
        pruneInterval: const Duration(milliseconds: 50),
      );
      await t.start();

      final List<List<PeerPresence>> emissions = <List<PeerPresence>>[];
      t.peerUpdates.listen(emissions.add);

      bridge.emit(_event('PEER0001', 42.0));
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(
        emissions.any((List<PeerPresence> e) => e.isEmpty),
        isTrue,
        reason: 'peer should have been pruned',
      );
      await t.dispose();
      await bridge.dispose();
    });

    test('stop marks streaming as ended and calls bridge.stop', () async {
      final _FakeBridge bridge = _FakeBridge();
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        sessionId: 'ABCD1234',
        peerId: 'EFGH5678',
      );
      await t.start();
      expect(t.isStreaming, isTrue);
      await t.stop();
      expect(t.isStreaming, isFalse);
      expect(bridge.started, isFalse);
      await t.dispose();
      await bridge.dispose();
    });
  });
}
