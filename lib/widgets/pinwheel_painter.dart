import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../models/session.dart';

class PinwheelPainter extends CustomPainter {
  const PinwheelPainter({
    required this.peers,
    required this.boundaryRadiusM,
    required this.centerRadius,
  });

  final List<SessionPeer> peers;
  final double boundaryRadiusM;
  final double centerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxDistance = math.max(boundaryRadiusM, 150.0);
    final ringRadius = math.min(size.width, size.height) * 0.38;

    final paint = Paint()
      ..color = Colors.blue.shade200
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(center, ringRadius, paint);

    final innerRing = Paint()
      ..color = Colors.blue.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, ringRadius * 0.75, innerRing);
    canvas.drawCircle(center, ringRadius * 0.5, innerRing);

    final centerDot = Paint()..color = Colors.white;
    canvas.drawCircle(center, centerRadius, centerDot);

    for (final peer in peers) {
      final angle = (peer.relativeBearingDeg - 90) * math.pi / 180;
      final distanceFactor = math.min(1, peer.relativeDistanceM / maxDistance);
      final curatedDistance = ringRadius * distanceFactor;
      final peerPoint = Offset(
        center.dx + math.cos(angle) * curatedDistance,
        center.dy + math.sin(angle) * curatedDistance,
      );

      final dotPaint = Paint()
        ..color = peer.outsideBoundary ? Colors.red : Colors.green
        ..style = PaintingStyle.fill;
      canvas.drawCircle(peerPoint, 8, dotPaint);

      final labelPainter = TextPainter(
        text: TextSpan(
          text: peer.emoji,
          style: const TextStyle(fontSize: 18),
        ),
        textDirection: Directionality.of(canvas.context ?? const SizedBox()),
      );
      labelPainter.layout();
      labelPainter.paint(canvas, peerPoint + const Offset(-8, -26));
    }
  }

  @override
  bool shouldRepaint(covariant PinwheelPainter oldDelegate) {
    return oldDelegate.peers != peers ||
        oldDelegate.boundaryRadiusM != boundaryRadiusM ||
        oldDelegate.centerRadius != centerRadius;
  }
}
