import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/location_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Session model', () {
    test('creates a valid session with peers', () {
      final session = Session(
        id: 's1',
        name: 'Test Session',
        boundaryRadiusMeters: 200,
        peers: const <PeerPresence>[
          PeerPresence(
            id: 'peer-1',
            label: 'Peer 1',
            bearingDegrees: 45,
            distanceMeters: 100,
          ),
        ],
      );

      expect(session.id, 's1');
      expect(session.name, 'Test Session');
      expect(session.peers.length, 1);
      expect(session.boundaryRadiusMeters, 200);
    });
  });

  group('LocationEngine', () {
    test('normalizes negative bearings into 0..360 range', () {
      const engine = LocationEngine();

      expect(engine.normalizeBearing(-30), 330);
      expect(engine.normalizeBearing(450), 90);
    });

    test('reports a peer within boundary range', () {
      const engine = LocationEngine();

      final inside = engine.isWithinBoundary(
        distanceMeters: 75,
        boundaryRadiusMeters: 100,
      );

      expect(inside, isTrue);
    });

    test('creates demo peers', () {
      const engine = LocationEngine();
      final peers = engine.createDemoPeers();

      expect(peers.length, 4);
      expect(peers.first.label, 'Peer A');
    });
  });
}
