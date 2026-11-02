import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models/session.dart';

void main() {
  runApp(const EchoPinApp());
}

class EchoPinApp extends StatelessWidget {
  const EchoPinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchoPinLocator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F6BFF)),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _sessionCodeController = TextEditingController();

  @override
  void dispose() {
    _sessionCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 118,
                    height: 118,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F6BFF).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.location_on_rounded,
                      size: 66,
                      color: Color(0xFF0F6BFF),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'EchoPinLocator',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Privacy-first, decentralized P2P location sharing',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: Color(0xFF526279),
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        final session = EchoSession.create(
                          boundaryRadiusM: 200,
                          peers: {
                            'peer-1': const SessionPeer(
                              peerId: 'peer-1',
                              displayName: 'Alice',
                              emoji: '🧡',
                              relativeBearingDeg: 24,
                              relativeDistanceM: 82,
                            ),
                            'peer-2': const SessionPeer(
                              peerId: 'peer-2',
                              displayName: 'Tumi',
                              emoji: '💙',
                              relativeBearingDeg: 162,
                              relativeDistanceM: 210,
                              outsideBoundary: true,
                            ),
                          },
                        );
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SessionScreen(session: session),
                          ),
                        );
                      },
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      label: const Text('Create session'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _showJoinDialog(context),
                      icon: const Icon(Icons.qr_code_2_rounded),
                      label: const Text('Join via QR code'),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Manual session code',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 1.2,
                      color: Color(0xFF526279),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _sessionCodeController,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      hintText: 'AB12CD',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () {
                      final code = _sessionCodeController.text.trim();
                      if (code.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Enter a session code first.')),
                        );
                        return;
                      }

                      final session = EchoSession.create(
                        sessionId: code,
                        boundaryRadiusM: 200,
                        peers: {
                          'peer-a': const SessionPeer(
                            peerId: 'peer-a',
                            displayName: 'Nearby',
                            emoji: '📍',
                            relativeBearingDeg: 96,
                            relativeDistanceM: 120,
                          ),
                        },
                      );

                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SessionScreen(session: session),
                        ),
                      );
                    },
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('Open session'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showJoinDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('QR join'),
          content: const Text(
            'QR and encrypted transport are the next implementation phase. Manual session entry already works locally.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.session});

  final EchoSession session;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late double _radius = widget.session.boundaryRadiusM;

  @override
  Widget build(BuildContext context) {
    final peers = widget.session.activePeers;
    final outside = peers.any((peer) => peer.outsideBoundary);

    return Scaffold(
      appBar: AppBar(
        title: Text('Session ${widget.session.sessionId}'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Active session',
                      style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.session.sessionId,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'boundary ${_radius.round()} m • peers ${peers.length}',
                      style: const TextStyle(color: Color(0xFF526279)),
                    ),
                  ],
                ),
              ),
            ),
            if (outside)
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.red),
                    SizedBox(width: 10),
                    Text(
                      'Boundary breach detected',
                      style: TextStyle(fontWeight: FontWeight.w700, color: Colors.red),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            const Text(
              'Boundary radius',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            Slider(
              value: _radius,
              min: 50,
              max: 500,
              divisions: 45,
              label: '${_radius.round()} m',
              onChanged: (value) {
                setState(() {
                  _radius = value;
                });
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [Text('50 m'), Text('500 m')],
            ),
            const SizedBox(height: 18),
            Container(
              height: 320,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE6EBF5)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: PinwheelWidget(peers: peers),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Peers',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            if (peers.isEmpty)
              const Text('No active peers.')
            else
              ...peers.map(
                (peer) => Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: peer.outsideBoundary ? Colors.red.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: peer.outsideBoundary ? Colors.red.shade200 : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        child: Text(peer.emoji),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              peer.displayName,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              '${peer.relativeDistanceM.round()} m • ${peer.relativeBearingDeg.round()}°',
                              style: const TextStyle(color: Color(0xFF526279)),
                            ),
                          ],
                        ),
                      ),
                      Chip(
                        label: Text(peer.outsideBoundary ? 'outside' : 'inside'),
                        backgroundColor: peer.outsideBoundary ? Colors.red.shade200 : Colors.green.shade200,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PinwheelWidget extends StatelessWidget {
  const PinwheelWidget({super.key, required this.peers});

  final List<SessionPeer> peers;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: PinwheelPainter(peers: peers),
      child: const SizedBox.expand(),
    );
  }
}

class PinwheelPainter extends CustomPainter {
  PinwheelPainter({required this.peers});

  final List<SessionPeer> peers;

  static const List<Color> _palette = [
    Color(0xFF0F6BFF),
    Color(0xFF14A39A),
    Color(0xFFFFA726),
    Color(0xFF7E57C2),
    Color(0xFFEF5350),
    Color(0xFF26A69A),
    Color(0xFF29B6F6),
    Color(0xFF5C6BC0),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 12;

    final bgPaint = Paint()..color = const Color(0xFFEAF3FF);
    canvas.drawCircle(center, radius, bgPaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFD9E8FF);
    canvas.drawCircle(center, radius, ringPaint);

    final cardinal = ['N', 'E', 'S', 'W'];
    final labelRadius = radius - 22;
    for (var i = 0; i < cardinal.length; i++) {
      final angle = ((i * 90) - 90) * math.pi / 180;
      final point = Offset(
        center.dx + labelRadius * math.cos(angle),
        center.dy + labelRadius * math.sin(angle),
      );
      final painter = TextPainter(
        text: TextSpan(
          text: cardinal[i],
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xFF526279),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(point.dx - painter.width / 2, point.dy - painter.height / 2),
      );
    }

    for (var i = 0; i < peers.length; i++) {
      final peer = peers[i];
      final angle = (peer.relativeBearingDeg - 90) * math.pi / 180;
      final visualDistance = _distanceToPixels(peer.relativeDistanceM, radius);
      final end = Offset(
        center.dx + visualDistance * math.cos(angle),
        center.dy + visualDistance * math.sin(angle),
      );

      final color = _palette[i % _palette.length];
      canvas.drawLine(
        center,
        end,
        Paint()
          ..strokeWidth = peer.outsideBoundary ? 2.6 : 1.8
          ..color = color,
      );

      canvas.drawCircle(
        end,
        peer.outsideBoundary ? 8 : 6,
        Paint()..color = color,
      );

      final emojiPainter = TextPainter(
        text: TextSpan(
          text: peer.emoji,
          style: const TextStyle(fontSize: 18),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelPoint = Offset(
        center.dx + (visualDistance + 14) * math.cos(angle),
        center.dy + (visualDistance + 14) * math.sin(angle),
      );
      emojiPainter.paint(
        canvas,
        Offset(
          labelPoint.dx - emojiPainter.width / 2,
          labelPoint.dy - emojiPainter.height / 2,
        ),
      );
    }
  }

  double _distanceToPixels(double distanceM, double radius) {
    final clamped = distanceM.clamp(0.0, 500.0).toDouble();
    return 18 + (clamped / 500) * (radius - 18);
  }

  @override
  bool shouldRepaint(covariant PinwheelPainter oldDelegate) {
    if (oldDelegate.peers.length != peers.length) {
      return true;
    }
    for (var i = 0; i < peers.length; i++) {
      final oldPeer = oldDelegate.peers[i];
      final newPeer = peers[i];
      if (oldPeer.peerId != newPeer.peerId ||
          oldPeer.relativeBearingDeg != newPeer.relativeBearingDeg ||
          oldPeer.relativeDistanceM != newPeer.relativeDistanceM ||
          oldPeer.outsideBoundary != newPeer.outsideBoundary ||
          oldPeer.isStale != newPeer.isStale) {
        return true;
      }
    }
    return false;
  }
}

