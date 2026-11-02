import 'dart:math' as math;

class GeoPoint {
  const GeoPoint({
    required this.latitude,
    required this.longitude,
    this.accuracyM = 0,
  });

  final double latitude;
  final double longitude;
  final double accuracyM;
}

class LocationEngine {
  const LocationEngine();

  static const double earthRadiusM = 6371000.0;

  static double computeDistance({
    required double lat1,
    required double lon1,
    required double lat2,
    required double lon2,
  }) {
    final lat1Rad = lat1 * math.pi / 180;
    final lat2Rad = lat2 * math.pi / 180;
    final deltaLat = (lat2 - lat1) * math.pi / 180;
    final deltaLon = (lon2 - lon1) * math.pi / 180;

    final a = math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
        math.cos(lat1Rad) *
            math.cos(lat2Rad) *
            math.sin(deltaLon / 2) *
            math.sin(deltaLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusM * c;
  }

  static double computeBearing({
    required double lat1,
    required double lon1,
    required double lat2,
    required double lon2,
  }) {
    final lat1Rad = lat1 * math.pi / 180;
    final lat2Rad = lat2 * math.pi / 180;
    final deltaLon = (lon2 - lon1) * math.pi / 180;

    final y = math.sin(deltaLon) * math.cos(lat2Rad);
    final x = math.cos(lat1Rad) * math.sin(lat2Rad) -
        math.sin(lat1Rad) * math.cos(lat2Rad) * math.cos(deltaLon);
    final angle = math.atan2(y, x) * 180 / math.pi;
    return (angle + 360) % 360;
  }

  static GeoPoint applyPlanarLaplaceNoise({
    required GeoPoint raw,
    required double epsilon,
  }) {
    final random = math.Random();
    final radius = _laplaceSample(random, epsilon);
    final theta = random.nextDouble() * math.pi * 2;
    final metersPerDegreeLat = 111_000.0;
    final metersPerDegreeLon = 111_000.0 * math.cos(raw.latitude * math.pi / 180);

    final latOffset = (radius * math.cos(theta)) / metersPerDegreeLat;
    final lonOffset = (radius * math.sin(theta)) / metersPerDegreeLon;

    return GeoPoint(
      latitude: raw.latitude + latOffset,
      longitude: raw.longitude + lonOffset,
      accuracyM: math.max(raw.accuracyM, radius.abs() * 1.2),
    );
  }

  static double estimateDistanceFromRssi({
    required double rssiDbm,
    double n = 2.5,
  }) {
    if (rssiDbm == 0) {
      return -1;
    }
    return math.pow(10, ((-rssiDbm - 50) / (10 * n))).toDouble();
  }

  static double _laplaceSample(math.Random random, double epsilon) {
    final u = (random.nextDouble() * 2.0) - 1.0;
    if (u == 0) {
      return 0;
    }
    final positive = u.abs();
    final value = -(1 / epsilon) * math.log1p(-(2 * positive) + 1);
    return u >= 0 ? value : -value;
  }
}
