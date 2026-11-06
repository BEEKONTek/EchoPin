import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/location_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const LocationEngine engine = LocationEngine();
  final DateTime t0 = DateTime.utc(2026, 1, 1, 12, 0, 5);

  test('offset is stable for one peer within one minute', () {
    final double a = engine.noiseOffsetFor(peerId: 'p', at: t0, sigma: 10);
    final double b = engine.noiseOffsetFor(
      peerId: 'p',
      at: t0.add(const Duration(seconds: 50)),
      sigma: 10,
    );
    expect(a, b);
  });

  test('offset differs between peers and between minutes', () {
    final double a = engine.noiseOffsetFor(peerId: 'p', at: t0, sigma: 10);
    final double other = engine.noiseOffsetFor(peerId: 'q', at: t0, sigma: 10);
    final double later = engine.noiseOffsetFor(
      peerId: 'p',
      at: t0.add(const Duration(minutes: 1)),
      sigma: 10,
    );
    expect(other, isNot(a));
    expect(later, isNot(a));
  });

  test('offset stays within [-sigma, sigma]', () {
    for (int i = 0; i < 500; i++) {
      final double o = engine.noiseOffsetFor(
        peerId: 'peer-$i',
        at: t0.add(Duration(minutes: i)),
        sigma: 7,
      );
      expect(o.abs(), lessThanOrEqualTo(7));
    }
  });

  test('sigma 0 leaves the peer untouched', () {
    const PeerPresence p = PeerPresence(
      id: 'p',
      label: 'P',
      bearingDegrees: 10,
      distanceMeters: 42,
    );
    expect(identical(engine.obfuscatePeer(p, sigma: 0, at: t0), p), isTrue);
  });

  test('obfuscated distance is never negative', () {
    const PeerPresence p = PeerPresence(
      id: 'p',
      label: 'P',
      bearingDegrees: 10,
      distanceMeters: 0,
    );
    for (int i = 0; i < 100; i++) {
      final PeerPresence o = engine.obfuscatePeer(
        p,
        sigma: 50,
        at: t0.add(Duration(minutes: i)),
      );
      expect(o.distanceMeters, greaterThanOrEqualTo(0));
    }
  });
}
