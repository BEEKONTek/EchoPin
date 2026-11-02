import 'package:flutter/foundation.dart';

import 'package:echo_pin/models/session.dart';

class SessionProvider extends ChangeNotifier {
  SessionProvider({Session? initialSession})
      : _session = initialSession ??
            Session(
              id: 'demo-session',
              name: 'Demo Session',
              peers: const <PeerPresence>[
                PeerPresence(
                  id: 'peer-a',
                  label: 'Peer A',
                  bearingDegrees: 30,
                  distanceMeters: 68,
                ),
                PeerPresence(
                  id: 'peer-b',
                  label: 'Peer B',
                  bearingDegrees: 120,
                  distanceMeters: 142,
                ),
              ],
            );

  Session _session;

  Session get session => _session;

  void updateSession(Session nextSession) {
    _session = nextSession;
    notifyListeners();
  }

  void updateSessionName(String name) {
    _session = _session.copyWith(name: name);
    notifyListeners();
  }

  void updateBoundaryRadius(double boundaryRadiusMeters) {
    _session = _session.copyWith(boundaryRadiusMeters: boundaryRadiusMeters);
    notifyListeners();
  }
}
