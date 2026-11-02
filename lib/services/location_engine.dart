import 'dart:math';

import 'package:echo_pin/models/session.dart';

class LocationEngine {
  const LocationEngine();

  double normalizeBearing(double degrees) {
    final normalized = degrees % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  double clamp(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  double applyNoise(double baseValue, {double sigma = 8}) {
    final random = Random();
    final noise = (random.nextDouble() * 2 - 1) * sigma;
    return baseValue + noise;
  }

  double relativeBearingDegrees({
    required double userHeading,
    required double peerBearing,
  }) {
    final offset = peerBearing - userHeading;
    return normalizeBearing(offset);
  }

  bool isWithinBoundary({
    required double distanceMeters,
    required double boundaryRadiusMeters,
  }) {
    return distanceMeters <= boundaryRadiusMeters;
  }

  double obfuscateDistance({
    required double rawDistanceMeters,
    double noiseSigma = 7,
  }) {
    return clamp(applyNoise(rawDistanceMeters, sigma: noiseSigma), 0, 10000);
  }

  List<PeerPresence> createDemoPeers() {
    return const <PeerPresence>[
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
      PeerPresence(
        id: 'peer-c',
        label: 'Peer C',
        bearingDegrees: 200,
        distanceMeters: 254,
      ),
      PeerPresence(
        id: 'peer-d',
        label: 'Peer D',
        bearingDegrees: 320,
        distanceMeters: 90,
      ),
    ];
  }
}
