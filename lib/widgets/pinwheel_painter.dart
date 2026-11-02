import 'dart:math';

import 'package:flutter/material.dart';

import 'package:echo_pin/models/session.dart';

class PinwheelPainter extends CustomPainter {
  const PinwheelPainter({
    required this.peers,
    required this.boundaryRadius,
    required this.centerRadius,
  });

  final List<PeerPresence> peers;
  final double boundaryRadius;
  final double centerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = min(size.width, size.height) / 2 - 16;
    final safeBoundary = boundaryRadius.clamp(40.0, maxRadius);

    final boundaryPaint = Paint()
      ..color = Colors.blue.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final innerRingPaint = Paint()
      ..color = Colors.blue.withOpacity(0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final centerPaint = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.fill;

    final peerPaint = Paint()..color = const Color(0xFF60A5FA);

    canvas.drawCircle(center, safeBoundary, boundaryPaint);
    canvas.drawCircle(center, centerRadius.clamp(14.0, 28.0), innerRingPaint);
    canvas.drawCircle(center, centerRadius.clamp(14.0, 28.0) * 0.6, innerRingPaint);
    canvas.drawCircle(center, centerRadius.clamp(14.0, 28.0) * 0.27, centerPaint);

    final youLabel = TextPainter(
      text: const TextSpan(
        text: 'You',
        style: TextStyle(
          color: Colors.black87,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    youLabel.layout();
    youLabel.paint(canvas, center - const Offset(18, 10));

    for (final peer in peers) {
      final angle = (peer.bearingDegrees - 90) * (pi / 180);
      final distance = (peer.distanceMeters / 450) * safeBoundary;
      final x = center.dx + cos(angle) * distance;
      final y = center.dy + sin(angle) * distance;
      final point = Offset(x, y);

      canvas.drawCircle(point, 10, peerPaint);

      final labelPainter = TextPainter(
        text: TextSpan(
          text: peer.label,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      );
      labelPainter.layout();
      labelPainter.paint(canvas, point + const Offset(12, -10));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
