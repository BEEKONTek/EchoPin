import 'dart:math';

import 'package:flutter/material.dart';

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
    final ringPaint = Paint()
      ..color = Colors.blue.withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final outer = Paint()
      ..color = Colors.blue.withOpacity(0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final inner = Paint()
      ..color = Colors.white.withOpacity(0.7)
      ..style = PaintingStyle.fill;

    final devicePaint = Paint()..color = const Color(0xFF60A5FA);

    canvas.drawCircle(center, boundaryRadius, ringPaint);
    canvas.drawCircle(center, centerRadius, outer);
    canvas.drawCircle(center, centerRadius * 0.5, outer);
    canvas.drawCircle(center, centerRadius * 0.22, inner);

    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'You',
        style: TextStyle(color: Colors.white, fontSize: 16),
      ),
      textDirection: Directionality.of(canvas.getTransform().storage.isEmpty ? const Offset(0, 0) : const Offset(0, 0)),
    );
    textPainter.layout();
    textPainter.paint(canvas, center - const Offset(18, 10));

    for (final peer in peers) {
      final angle = (peer.bearingDegrees - 90) * (pi / 180);
      final distance = (peer.distanceMeters / 450) * boundaryRadius;
      final x = center.dx + cos(angle) * distance;
      final y = center.dy + sin(angle) * distance;
      final point = Offset(x, y);

      canvas.drawCircle(point, 10, devicePaint);
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

class PeerPresence {
  const PeerPresence({
    required this.id,
    required this.label,
    required this.bearingDegrees,
    required this.distanceMeters,
  });

  final String id;
  final String label;
  final double bearingDegrees;
  final double distanceMeters;
}
