// LOCATION ENGINE: bearing maths and privacy noise for distances.
//
// Distances come from Bluetooth signal strength, not GPS. EchoPin never
// records coordinates. Before any distance reaches the screen, noise is
// added so a precise position can't be read off the display. The noise for
// a given person is stable within each minute, so labels don't jitter
// every frame.

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

  /// Deterministic jitter in `[-sigma, sigma]` for one peer within one
  /// wall-clock minute.
  ///
  /// Holding the offset constant per peer per minute means repeated samples
  /// inside the same minute cannot be averaged to recover the true distance,
  /// while the offset still changes over time so it is not a fixed bias.
  double noiseOffsetFor({
    required String peerId,
    required DateTime at,
    required double sigma,
  }) {
    if (sigma <= 0) return 0;
    final int minute = at.millisecondsSinceEpoch ~/ 60000;
    final Random rng = Random(_fnv1a('$peerId:$minute'));
    return (rng.nextDouble() * 2 - 1) * sigma;
  }

  /// Applies [noiseOffsetFor] to a peer's distance. This is the only place
  /// peer distances are altered before they reach providers and the UI.
  PeerPresence obfuscatePeer(
    PeerPresence peer, {
    required double sigma,
    required DateTime at,
  }) {
    if (sigma <= 0) return peer;
    final double offset = noiseOffsetFor(peerId: peer.id, at: at, sigma: sigma);
    return peer.copyWith(
      distanceMeters: clamp(peer.distanceMeters + offset, 0, 10000),
    );
  }

  /// 32-bit FNV-1a. Stable across runs and platforms (unlike
  /// `String.hashCode`), and safe for dart2js where ints are doubles.
  static int _fnv1a(String input) {
    int hash = 0x811c9dc5;
    for (final int unit in input.codeUnits) {
      hash = _fnvStep(hash, unit & 0xff);
      hash = _fnvStep(hash, (unit >> 8) & 0xff);
    }
    return hash % 0x80000000;
  }

  /// `(hash ^ byte) * 0x01000193 mod 2^32`, split as `2^24 + 0x193` so every
  /// intermediate stays below 2^53 (exact on the web, where ints are doubles).
  static int _fnvStep(int hash, int byte) {
    final int h = (hash ^ byte) % 0x100000000;
    return (h * 0x193 + (h % 0x100) * 0x1000000) % 0x100000000;
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
