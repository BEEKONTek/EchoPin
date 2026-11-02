import 'dart:math';

import 'package:echo_pin/models/session.dart';

class MeshService {
  MeshService();

  Session createSession(String name, {double boundaryRadiusMeters = 150}) {
    final sessionId = 'session-${DateTime.now().millisecondsSinceEpoch}';
    final basePeers = <PeerPresence>[
      const PeerPresence(
        id: 'peer-a',
        label: 'Peer A',
        bearingDegrees: 30,
        distanceMeters: 68,
      ),
      const PeerPresence(
        id: 'peer-b',
        label: 'Peer B',
        bearingDegrees: 120,
        distanceMeters: 142,
      ),
      const PeerPresence(
        id: 'peer-c',
        label: 'Peer C',
        bearingDegrees: 200,
        distanceMeters: 254,
      ),
    ];

    return Session(
      id: sessionId,
      name: name,
      boundaryRadiusMeters: boundaryRadiusMeters,
      peers: basePeers,
    );
  }

  Session joinSession({
    required String sessionName,
    required String sessionId,
    double boundaryRadiusMeters = 150,
  }) {
    final random = Random();

    final peers = List<PeerPresence>.generate(
      3,
      (index) => PeerPresence(
        id: 'peer-${index + 1}',
        label: 'Peer ${index + 1}',
        bearingDegrees: (index * 110.0 + 35) % 360,
        distanceMeters: 40 + random.nextInt(180).toDouble(),
      ),
    );

    return Session(
      id: sessionId,
      name: sessionName,
      boundaryRadiusMeters: boundaryRadiusMeters,
      peers: peers,
    );
  }
}
