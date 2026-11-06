import 'dart:math';

import 'package:flutter/material.dart';

import 'package:echo_pin/models/session.dart';

/// Colors for [PinwheelPainter], derived from the active theme so the view
/// reads correctly in light and dark mode.
@immutable
class PinwheelColors {
  const PinwheelColors({
    required this.background,
    required this.grid,
    required this.boundary,
    required this.inside,
    required this.outside,
    required this.synthetic,
    required this.label,
    this.alert = const Color(0xFFDC2626),
  });

  factory PinwheelColors.of(ColorScheme scheme) => PinwheelColors(
    background: scheme.surfaceContainerHighest,
    grid: scheme.outlineVariant,
    boundary: scheme.primary,
    inside: scheme.primary,
    outside: scheme.error,
    synthetic: scheme.tertiary,
    label: scheme.onSurface,
  );

  final Color background;
  final Color grid;
  final Color boundary;
  final Color inside;
  final Color outside;
  final Color synthetic;
  final Color label;
  final Color alert;

  @override
  bool operator ==(Object other) =>
      other is PinwheelColors &&
      other.background == background &&
      other.grid == grid &&
      other.boundary == boundary &&
      other.inside == inside &&
      other.outside == outside &&
      other.synthetic == synthetic &&
      other.label == label;

  @override
  int get hashCode => Object.hash(
    background,
    grid,
    boundary,
    inside,
    outside,
    synthetic,
    label,
  );
}

/// Draws peers as spokes ("blades") radiating from the user at the centre.
///
/// Distances are in metres and mapped linearly so that [rangeMeters] lands
/// on the outer edge. The boundary circle therefore sits exactly where a
/// peer at [boundaryRadius] metres is drawn. Peers beyond the range are
/// pinned to the edge with a hollow marker.
class PinwheelPainter extends CustomPainter {
  const PinwheelPainter({
    required this.peers,
    required this.boundaryRadius,
    required this.centerRadius,
    this.rangeMeters = 500,
    this.colors,
    this.syntheticIds = const <String>{},
    this.highlightIds = const <String>{},
    this.pulse = 0,
  });

  final List<PeerPresence> peers;

  /// Boundary radius in metres.
  final double boundaryRadius;
  final double centerRadius;
  final double rangeMeters;
  final PinwheelColors? colors;
  final Set<String> syntheticIds;

  /// Peers with a live SOS, drawn with a red halo.
  final Set<String> highlightIds;

  /// 0..1 animation phase for the SOS halo.
  final double pulse;

  static const double edgePadding = 20;

  /// Outer drawable radius in pixels for a canvas of [size].
  static double outerRadiusFor(Size size) =>
      max(0, min(size.width, size.height) / 2 - edgePadding);

  @override
  void paint(Canvas canvas, Size size) {
    final PinwheelColors c =
        colors ??
        PinwheelColors.of(ColorScheme.fromSeed(seedColor: Colors.blue));
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double outer = outerRadiusFor(size);
    if (outer <= 0) return;
    final double pxPerMeter = outer / rangeMeters;

    // Backdrop disc.
    canvas.drawCircle(center, outer, Paint()..color = c.background);

    // Range rings every 100 m with labels.
    final Paint gridPaint = Paint()
      ..color = c.grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (double m = 100; m <= rangeMeters; m += 100) {
      canvas.drawCircle(center, m * pxPerMeter, gridPaint);
      _text(
        canvas,
        '${m.round()} m',
        center + Offset(4, -m * pxPerMeter + 2),
        c.label.withValues(alpha: 0.5),
        10,
      );
    }
    // North marker.
    _text(
      canvas,
      'N',
      center + Offset(-4, -outer - 16),
      c.label.withValues(alpha: 0.7),
      12,
      bold: true,
    );

    // Boundary.
    final double boundaryPx = boundaryRadius.clamp(0, rangeMeters) * pxPerMeter;
    canvas.drawCircle(
      center,
      boundaryPx,
      Paint()..color = c.boundary.withValues(alpha: 0.10),
    );
    canvas.drawCircle(
      center,
      boundaryPx,
      Paint()
        ..color = c.boundary.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Peers: spoke + dot + label. Peers without a measured distance
    // (Wi-Fi only) cannot be placed honestly, so they are not drawn.
    for (final PeerPresence peer in peers) {
      if (!peer.hasDistance) continue;
      final bool inside = peer.distanceMeters <= boundaryRadius;
      final bool beyond = peer.distanceMeters > rangeMeters;
      final bool synthetic = syntheticIds.contains(peer.id);
      final bool unconfirmed = !peer.authenticated;
      final Color color = unconfirmed
          ? c.grid
          : synthetic
          ? c.synthetic
          : (inside ? c.inside : c.outside);
      final double angle = (peer.bearingDegrees - 90) * (pi / 180);
      final double r = min(peer.distanceMeters, rangeMeters) * pxPerMeter;
      final Offset point = center + Offset(cos(angle) * r, sin(angle) * r);

      if (!unconfirmed) {
        canvas.drawLine(
          center,
          point,
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..strokeWidth = 2,
        );
      }
      if (highlightIds.contains(peer.id)) {
        // Live SOS: a red halo, pulsing with [pulse].
        final double halo = 13 + 6 * pulse;
        canvas.drawCircle(
          point,
          halo,
          Paint()
            ..color = c.alert.withValues(alpha: 0.85 - 0.6 * pulse)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
      canvas.drawCircle(
        point,
        8,
        Paint()
          ..color = color
          ..style = beyond || unconfirmed
              ? PaintingStyle.stroke
              : PaintingStyle.fill
          ..strokeWidth = 2.5,
      );
      _text(
        canvas,
        peer.label,
        point + const Offset(11, -8),
        unconfirmed ? c.label.withValues(alpha: 0.5) : c.label,
        12,
      );
    }

    // The user.
    final double you = centerRadius.clamp(6.0, 14.0);
    canvas.drawCircle(center, you, Paint()..color = c.boundary);
    canvas.drawCircle(center, you * 0.45, Paint()..color = c.background);
  }

  static void _text(
    Canvas canvas,
    String text,
    Offset at,
    Color color,
    double size, {
    bool bold = false,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant PinwheelPainter old) =>
      old.peers != peers ||
      old.boundaryRadius != boundaryRadius ||
      old.centerRadius != centerRadius ||
      old.rangeMeters != rangeMeters ||
      old.colors != colors ||
      old.syntheticIds != syntheticIds ||
      old.highlightIds != highlightIds ||
      old.pulse != pulse;
}

/// Interactive pinwheel: drag anywhere on the disc to set the boundary to
/// the touched distance. Peers with a live SOS pulse.
class PinwheelView extends StatefulWidget {
  const PinwheelView({
    super.key,
    required this.peers,
    required this.boundaryRadius,
    this.onBoundaryChanged,
    this.rangeMeters = 500,
    this.minBoundary = 50,
    this.syntheticIds = const <String>{},
    this.highlightIds = const <String>{},
  });

  final List<PeerPresence> peers;
  final double boundaryRadius;
  final ValueChanged<double>? onBoundaryChanged;
  final double rangeMeters;
  final double minBoundary;
  final Set<String> syntheticIds;
  final Set<String> highlightIds;

  @override
  State<PinwheelView> createState() => _PinwheelViewState();
}

class _PinwheelViewState extends State<PinwheelView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant PinwheelView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  /// Animate only while something needs attention: an idle pinwheel costs
  /// no frames.
  void _syncPulse() {
    if (widget.highlightIds.isNotEmpty) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else if (_pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PinwheelColors colors = PinwheelColors.of(
      Theme.of(context).colorScheme,
    );
    final int placed = widget.peers
        .where((PeerPresence p) => p.hasDistance)
        .length;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        void update(Offset local) {
          final ValueChanged<double>? cb = widget.onBoundaryChanged;
          if (cb == null) return;
          final double outer = PinwheelPainter.outerRadiusFor(size);
          if (outer <= 0) return;
          final double px = (local - size.center(Offset.zero)).distance;
          cb(
            (px / outer * widget.rangeMeters).clamp(
              widget.minBoundary,
              widget.rangeMeters,
            ),
          );
        }

        return Semantics(
          label:
              'Pinwheel: $placed people placed, boundary '
              '${widget.boundaryRadius.round()} metres',
          hint: widget.onBoundaryChanged == null
              ? null
              : 'Drag to set the boundary',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (DragStartDetails d) => update(d.localPosition),
            onPanUpdate: (DragUpdateDetails d) => update(d.localPosition),
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (BuildContext context, Widget? _) => CustomPaint(
                size: size,
                painter: PinwheelPainter(
                  peers: widget.peers,
                  boundaryRadius: widget.boundaryRadius,
                  centerRadius: 10,
                  rangeMeters: widget.rangeMeters,
                  colors: colors,
                  syntheticIds: widget.syntheticIds,
                  highlightIds: widget.highlightIds,
                  pulse: _pulse.value,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
