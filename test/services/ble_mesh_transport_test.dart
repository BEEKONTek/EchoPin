import 'dart:async';
import 'dart:typed_data';

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/ble_mesh_transport.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_ble_bridge.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late FakeBleBridge bridge;

  setUp(() => bridge = FakeBleBridge());
  tearDown(() => bridge.dispose());

  group('BleMeshTransport lifecycle', () {
    test('adapter on: starts the radio and reports running', () async {
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      expect(await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME'), isTrue);
      expect(bridge.startCalls, 1);
      expect(t.status.health, TransportHealth.running);
      expect(t.isStreaming, isTrue);
      await t.stop();
      expect(bridge.stopCalls, 1);
    });

    test(
      'Bluetooth off: waits with a precise problem, recovers when on',
      () async {
        bridge.state = BleAdapterState.off;
        final BleMeshTransport t = BleMeshTransport(bridge: bridge);
        expect(
          await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME'),
          isTrue,
        );
        expect(t.status.health, TransportHealth.waiting);
        expect(
          t.status.problem,
          isA<RadioUnavailableError>().having(
            (RadioUnavailableError e) => e.problem,
            'problem',
            RadioProblem.off,
          ),
        );
        expect(bridge.startCalls, 0);

        bridge.setAdapter(BleAdapterState.on);
        await _settle();
        expect(bridge.startCalls, 1);
        expect(t.status.health, TransportHealth.running);

        bridge.setAdapter(BleAdapterState.off);
        await _settle();
        expect(t.status.health, TransportHealth.waiting);
        await t.stop();
      },
    );

    test('permission denied: waits; retry after granting starts it', () async {
      bool granted = false;
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        ensurePermission: () async => granted,
      );
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      expect(t.status.problem, isA<PermissionDeniedError>());
      granted = true;
      await t.retry();
      expect(t.status.health, TransportHealth.running);
      await t.stop();
    });

    test('unsupported hardware: start returns false', () async {
      bridge.state = BleAdapterState.unsupported;
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      expect(await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME'), isFalse);
      expect(t.status.health, TransportHealth.unsupported);
      await t.stop();
    });

    test('native start refusal is reported, not thrown', () async {
      bridge.startResult = false;
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      expect(t.status.health, TransportHealth.waiting);
      expect(t.status.problem, isA<TransportError>());
      await t.stop();
    });

    test('enable request is forwarded to the OS', () async {
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      await t.requestEnable();
      expect(bridge.enableRequested, isTrue);
      await t.stop();
    });
  });

  group('BleMeshTransport presence', () {
    test('sightings become presence; self is filtered out', () async {
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      final List<List<PeerPresence>> seen = <List<PeerPresence>>[];
      t.peerUpdates.listen(seen.add);
      bridge
        ..emitSighting('MEMEMEME', 1)
        ..emitSighting('PEERAAAA', 12.5);
      await _settle();
      expect(seen.last.map((PeerPresence p) => p.id), <String>['PEERAAAA']);
      expect(seen.last.single.distanceMeters, 12.5);
      expect(t.reachablePeers, <String>{'PEERAAAA'});
      expect(t.status.reachable, 1);
      await t.stop();
    });

    test('bearing is stable per peer and across runs', () {
      expect(
        BleMeshTransport.stableBearing('PEERAAAA'),
        BleMeshTransport.stableBearing('PEERAAAA'),
      );
      expect(
        BleMeshTransport.stableBearing('PEERAAAA'),
        inInclusiveRange(0, 359),
      );
    });

    test('stale peers are pruned', () async {
      final BleMeshTransport t = BleMeshTransport(
        bridge: bridge,
        staleTimeout: const Duration(milliseconds: 30),
        pruneInterval: const Duration(milliseconds: 10),
      );
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      bridge.emitSighting('PEERAAAA', 5);
      await _settle();
      expect(t.reachablePeers, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(t.reachablePeers, isEmpty);
      await t.stop();
    });

    test('turning Bluetooth off clears everyone seen over it', () async {
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      bridge.emitSighting('PEERAAAA', 5);
      await _settle();
      bridge.setAdapter(BleAdapterState.off);
      await _settle();
      expect(t.reachablePeers, isEmpty);
      await t.stop();
    });
  });

  group('BleMeshTransport messages', () {
    test('frames pass through; sends carry the announce hint', () async {
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      final Completer<TransportFrame> got = Completer<TransportFrame>();
      t.frames.listen(got.complete);
      bridge.emitFrame(Uint8List.fromList(<int>[1, 2, 3]));
      final TransportFrame f = await got.future;
      expect(f.bytes, <int>[1, 2, 3]);
      expect(f.link, PeerLink.ble);

      await t.send(Uint8List(4), urgency: SendUrgency.announce);
      await t.send(Uint8List(4), to: <String>{'PEERAAAA'});
      expect(bridge.sent[0].announce, isTrue);
      expect(bridge.sent[1].announce, isFalse);
      expect(bridge.sent[1].to, <String>{'PEERAAAA'});
      await t.stop();
    });

    test('nothing is sent while the radio is down', () async {
      bridge.state = BleAdapterState.off;
      final BleMeshTransport t = BleMeshTransport(bridge: bridge);
      await t.start(sessionId: 'SESSION1', peerId: 'MEMEMEME');
      expect(await t.send(Uint8List(4)), 0);
      expect(bridge.sent, isEmpty);
      await t.stop();
    });
  });
}
