import 'dart:math';

import 'package:flutter/material.dart';

class RealTimeLocation { 
  const RealTimeLocation({
    required this.latitude,
    required this.longitude,
    required this.bearingDegrees,
  });

  final double latitude;
  final double longitude;
  final double bearingDegrees;

  factory RealTimeLocation.example() {
    return const RealTimeLocation(
      latitude: 51.5074,
      longitude: -0.1278,
      bearingDegrees: 45,
    );
  }
}

class LocationEngine {
  const LocationEngine();

  double normalizeBearing(double degrees) {
    final normalized = degrees % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  bool isWithinBoundary({
    required double distanceMeters,
    required double boundaryRadiusMeters,
  }) {
    return distanceMeters <= boundaryRadiusMeters;
  }

  double relativeBearingDegrees({
    required double userHeading,
    required double peerBearing,
  }) {
    return normalizeBearing(peerBearing - userHeading);
  }

  double distanceMetersBetween({
    required double lat1,
    required double lon1,
    required double lat2,
    required double lon2,
  }) {
    const radius = 6371000.0;
    final lat1Rad = lat1 * pi / 180;
    final lat2Rad = lat2 * pi / 180;
    final deltaLat = (lat2 - lat1) * pi / 180;
    final deltaLon = (lon2 - lon1) * pi / 180;

    final a = sin(deltaLat / 2) * sin(deltaLat / 2) +
        cos(lat1Rad) * cos(lat2Rad) * sin(deltaLon / 2) * sin(deltaLon / 2);

    return 2 * radius * asin(sqrt(a));
  }
}
