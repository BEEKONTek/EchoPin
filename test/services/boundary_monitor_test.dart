import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/boundary_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

PeerPresence _peer(String id, double distanceMeters) {
  return PeerPresence(
    id: id,
    label: 'Peer $id',
    bearingDegrees: 0,
    distanceMeters: distanceMeters,
  );
}

void main() {
  final DateTime now = DateTime.utc(2024, 6, 1);

  group('computeCrossings', () {
    test('detects a peer entering the boundary', () {
      final List<BoundaryAlert> alerts = computeCrossings(
        previous: <PeerPresence>[_peer('a', 100)],
        current: <PeerPresence>[_peer('a', 5)],
        boundaryRadiusMeters: 50,
        now: now,
      );
      expect(alerts.length, 1);
      expect(alerts.single.direction, CrossingDirection.entered);
      expect(alerts.single.peerId, 'a');
    });

    test('detects a peer exiting the boundary', () {
      final List<BoundaryAlert> alerts = computeCrossings(
        previous: <PeerPresence>[_peer('a', 5)],
        current: <PeerPresence>[_peer('a', 100)],
        boundaryRadiusMeters: 50,
        now: now,
      );
      expect(alerts.single.direction, CrossingDirection.exited);
    });

    test('no alert when a peer stays inside', () {
      final List<BoundaryAlert> alerts = computeCrossings(
        previous: <PeerPresence>[_peer('a', 10)],
        current: <PeerPresence>[_peer('a', 20)],
        boundaryRadiusMeters: 50,
        now: now,
      );
      expect(alerts, isEmpty);
    });

    test('no alert when a peer stays outside', () {
      final List<BoundaryAlert> alerts = computeCrossings(
        previous: <PeerPresence>[_peer('a', 100)],
        current: <PeerPresence>[_peer('a', 200)],
        boundaryRadiusMeters: 50,
        now: now,
      );
      expect(alerts, isEmpty);
    });

    test('no alert for a peer seen for the first time', () {
      final List<BoundaryAlert> alerts = computeCrossings(
        previous: const <PeerPresence>[],
        current: <PeerPresence>[_peer('a', 5)],
        boundaryRadiusMeters: 50,
        now: now,
      );
      expect(alerts, isEmpty);
    });

    test('exactly-on-radius counts as inside', () {
      final List<BoundaryAlert> alerts = computeCrossings(
        previous: <PeerPresence>[_peer('a', 50)],
        current: <PeerPresence>[_peer('a', 51)],
        boundaryRadiusMeters: 50,
        now: now,
      );
      expect(alerts.single.direction, CrossingDirection.exited);
    });

    test('multiple peers crossing produce multiple alerts', () {
      final List<BoundaryAlert> alerts = computeCrossings(
        previous: <PeerPresence>[
          _peer('a', 100),
          _peer('b', 5),
          _peer('c', 10),
        ],
        current: <PeerPresence>[_peer('a', 5), _peer('b', 100), _peer('c', 15)],
        boundaryRadiusMeters: 50,
        now: now,
      );
      expect(alerts.length, 2);
      expect(
        alerts.map((BoundaryAlert a) => a.peerId),
        containsAll(<String>['a', 'b']),
      );
    });

    test('alert id is unique per crossing timestamp', () {
      final List<BoundaryAlert> first = computeCrossings(
        previous: <PeerPresence>[_peer('a', 100)],
        current: <PeerPresence>[_peer('a', 5)],
        boundaryRadiusMeters: 50,
        now: now,
      );
      final List<BoundaryAlert> second = computeCrossings(
        previous: <PeerPresence>[_peer('a', 100)],
        current: <PeerPresence>[_peer('a', 5)],
        boundaryRadiusMeters: 50,
        now: now.add(const Duration(seconds: 1)),
      );
      expect(first.single.id, isNot(second.single.id));
    });

    test('empty snapshots produce no alerts', () {
      final List<BoundaryAlert> alerts = computeCrossings(
        previous: const <PeerPresence>[],
        current: const <PeerPresence>[],
        boundaryRadiusMeters: 50,
        now: now,
      );
      expect(alerts, isEmpty);
    });
  });
}
