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
        colorSchemeSeed: const Color(0xFF0F6BFF),
        brightness: Brightness.light,
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
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F6BFF).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.location_on_rounded,
                      size: 64,
                      color: Color(0xFF0F6BFF),
                    ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'EchoPinLocator',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 34,
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
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        final session = EchoSession.create(
                          sessionId: _generateSessionCode(),
                          boundaryRadiusM: 200,
                          peers: [
                            SessionPeer(
                              peerId: 'peer-1',
                              displayName: 'Alice',
                              emoji: '🧡',
                              relativeBearingDeg: 45,
                              relativeDistanceM: 80,
                            ),
                            SessionPeer(
                              peerId: 'peer-2',
                              displayName: 'Tumi',
                              emoji: '💙',
                              relativeBearingDeg: 220,
                              relativeDistanceM: 210,
                              outsideBoundary: true,
                            ),
                          ],
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
                  const Divider(),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _sessionCodeController,
                    textAlign: TextAlign.center,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'ENTER SESSION CODE',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () {
                        final code = _sessionCodeController.text.trim();
                        if (code.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Enter a session code first.')),
                          );
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SessionScreen(
                              session: EchoSession.create(
                                sessionId: code,
                                boundaryRadiusM: 200,
                                peers: const [
                                  SessionPeer(
                                    peerId: 'manual-peer',
                                    displayName: 'Nearby',
                                    emoji: '📍',
                                    relativeBearingDeg: 130,
                                    relativeDistanceM: 60,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      child: const Text('Open session'),
                    ),
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
            'QR join is implemented as a follow-on feature in the next phase. Manual code entry is available here for the working prototype.',
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

  String _generateSessionCode() {
    const charset = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = math.Random();
    final buffer = StringBuffer();
    for (var i = 0; i < 6; i++) {
      buffer.write(charset[random.nextInt(charset.length)]);
    }
    return buffer.toString();
  }
}

class SessionScreen extends StatelessWidget {
  const SessionScreen({super.key, required this.session});

  final EchoSession session;

  @override
  Widget build(BuildContext context) {
    final peers = session.activePeers;
    final hasOutsidePeer = peers.any((peer) => peer.outsideBoundary);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Active session',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        session.sessionId,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Boundary: ${session.boundaryRadiusM.round()} m • peers: ${peers.length}',
                        style: const TextStyle(color: Color(0xFF526279)),
                      ),
                    ],
                  ),
                ),
              ),
              if (hasOutsidePeer)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 14),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    border: Border.all(color: Colors.red.shade200),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.red),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Boundary breach detected',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              const Text(
                'Boundary radius',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              StatefulBuilder(
                builder: (context, setState) {
                  double radius = session.boundaryRadiusM;
                  return Column(
                    children: [
                      Slider(
                        value: radius,
                        min: 50,
                        max: 500,
                        divisions: 45,
                        label: '${radius.round()} m',
                        onChanged: (value) {
                          radius = value;
                          setState(() {});
                        },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('50 m'),
                          Text('${radius.round()} m'),
                          const Text('500 m'),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 260,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: PinwheelWidget(peers: peers),
                  ),
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
                  (peer) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                            radius: 20,
                            backgroundColor: peer.outsideBoundary ? Colors.red.shade100 : Colors.blue.shade100,
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
                                  '${peer.relativeDistanceM.round()} m away • ${peer.relativeBearingDeg.round()}°',
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
                ),
            ],
          ),
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
    Color(0xFF00A7A7),
    Color(0xFF7C4DFF),
    Color(0xFF3ECF8E),
    Color(0xFFFF9F1C),
    Color(0xFFEC407A),
    Color(0xFF78909C),
    Color(0xFF26C6DA),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = math.min(size.width, size.height) / 2 - 8;

    canvas.drawCircle(
      center,
      outer,
      Paint()..color = const Color(0xFFF3F8FF),
    );

    final ring = Paint()
      ..color = const Color(0xFFBFD8FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, outer, ring);

    const labels = ['N', 'E', 'S', 'W'];
    final labelRadius = outer - 18;
    for (var i = 0; i < labels.length; i++) {
      final angle = (i * 90 - 90) * math.pi / 180;
      final point = Offset(
        center.dx + labelRadius * math.cos(angle),
        center.dy + labelRadius * math.sin(angle),
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: const TextStyle(
            color: Color(0xFF526279),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        point - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    }

    for (var i = 0; i < peers.length; i++) {
      final peer = peers[i];
      final angle = (peer.relativeBearingDeg - 90) * math.pi / 180;
      final distancePx = _distanceToPixels(peer.relativeDistanceM, outer);
      final end = Offset(
        center.dx + distancePx * math.cos(angle),
        center.dy + distancePx * math.sin(angle),
      );

      final armPaint = Paint()
        ..color = _palette[i % _palette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = peer.outsideBoundary ? 2.5 : 1.8
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(center, end, armPaint);

      final dotPaint = Paint()
        ..color = _palette[i % _palette.length]
        ..style = PaintingStyle.fill;
      canvas.drawCircle(end, peer.outsideBoundary ? 8 : 6, dotPaint);

      final labelPainter = TextPainter(
        text: TextSpan(
          text: peer.emoji,
          style: const TextStyle(fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelOffset = Offset(
        center.dx + (distancePx + 14) * math.cos(angle),
        center.dy + (distancePx + 14) * math.sin(angle),
      );
      labelPainter.paint(
        canvas,
        labelOffset - Offset(labelPainter.width / 2, labelPainter.height / 2),
      );
    }
  }

  double _distanceToPixels(double distanceM, double maxPx) {
    final clamped = distanceM.clamp(0.0, 500.0).toDouble();
    final scale = (maxPx - 20) / 500;
    return 20 + clamped * scale;
  }

  @override
  bool shouldRepaint(covariant PinwheelPainter oldDelegate) {
    return oldDelegate.peers.length != peers.length;
  }
}
