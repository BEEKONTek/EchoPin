import 'dart:math' as math;

import 'package:flutter/material.dart';

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
        colorSchemeSeed: const Color(0xFF1E88E5),
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
  final _sessionCodeController = TextEditingController();

  @override
  void dispose() {
    _sessionCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.location_on_rounded,
                    size: 90,
                    color: Color(0xFF0F6BFF),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'EchoPinLocator',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Privacy-first, decentralized location sharing',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.black54),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        final code = _generateSessionCode();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SessionScreen(
                              session: EchoSession(
                                sessionId: code,
                                boundaryRadiusM: 200,
                                peers: [
                                  SessionPeer(
                                    peerId: 'peer-1',
                                    displayName: 'Alice',
                                    emoji: '🧡',
                                    relativeBearingDeg: 30,
                                    relativeDistanceM: 90,
                                  ),
                                  SessionPeer(
                                    peerId: 'peer-2',
                                    displayName: 'Tumi',
                                    emoji: '💙',
                                    relativeBearingDeg: 200,
                                    relativeDistanceM: 210,
                                    outsideBoundary: true,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      label: const Text('Create session'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _showJoinDialog(context);
                      },
                      icon: const Icon(Icons.qr_code_2_rounded),
                      label: const Text('Join via QR code'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _sessionCodeController,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Session code',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () {
                        final code = _sessionCodeController.text.trim();
                        if (code.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Enter a session code')),
                          );
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SessionScreen(
                              session: EchoSession(
                                sessionId: code,
                                boundaryRadiusM: 200,
                                peers: const [
                                  SessionPeer(
                                    peerId: 'peer-3',
                                    displayName: 'Jules',
                                    emoji: '💚',
                                    relativeBearingDeg: 120,
                                    relativeDistanceM: 75,
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
            'QR join is a pending feature. This shell app supports manual session entry and continues the flow for the prototype.',
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

class EchoSession {
  EchoSession({
    required this.sessionId,
    required this.boundaryRadiusM,
    required this.peers,
  });

  final String sessionId;
  final double boundaryRadiusM;
  final List<SessionPeer> peers;

  List<SessionPeer> get activePeers =>
      peers.where((peer) => !peer.isStale).toList()
        ..sort((a, b) => a.relativeDistanceM.compareTo(b.relativeDistanceM));

  bool get hasOutsidePeer => activePeers.any((peer) => peer.outsideBoundary);
}

class SessionPeer {
  const SessionPeer({
    required this.peerId,
    required this.displayName,
    required this.emoji,
    required this.relativeBearingDeg,
    required this.relativeDistanceM,
    this.outsideBoundary = false,
    this.lastSeen,
  });

  final String peerId;
  final String displayName;
  final String emoji;
  final double relativeBearingDeg;
  final double relativeDistanceM;
  final bool outsideBoundary;
  final DateTime? lastSeen;

  bool get isStale {
    final seen = lastSeen ?? DateTime.now();
    return DateTime.now().difference(seen).inSeconds > 10;
  }
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.session});

  final EchoSession session;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late double _boundaryRadius;

  @override
  void initState() {
    super.initState();
    _boundaryRadius = widget.session.boundaryRadiusM;
  }

  @override
  Widget build(BuildContext context) {
    final peers = widget.session.activePeers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session'),
      ),
      body: SafeArea(
        child: Padding(
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
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.session.sessionId,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text('Expiry: 8 hours • mesh shell prototype'),
                    ],
                  ),
                ),
              ),
              if (widget.session.hasOutsidePeer)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 18, bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.red.shade300),
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
              const SizedBox(height: 8),
              const Text(
                'Boundary radius',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              Slider(
                value: _boundaryRadius,
                min: 50,
                max: 500,
                divisions: 45,
                label: '${_boundaryRadius.round()} m',
                onChanged: (value) {
                  setState(() {
                    _boundaryRadius = value;
                  });
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('50 m'),
                  Text('${_boundaryRadius.round()} m'),
                  const Text('500 m'),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 260,
                width: double.infinity,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: PinwheelWidget(
                      radiusM: _boundaryRadius,
                      peers: peers,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Peers',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.builder(
                  itemCount: peers.length,
                  itemBuilder: (context, index) {
                    final peer = peers[index];
                    final outside = peer.outsideBoundary;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        decoration: BoxDecoration(
                          color: outside ? Colors.red.shade50 : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: outside ? Colors.red.shade200 : Colors.grey.shade300,
                          ),
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: outside ? Colors.red.shade100 : Colors.blue.shade100,
                            child: Text(peer.emoji),
                          ),
                          title: Text(peer.displayName),
                          subtitle: Text(
                            '${peer.relativeDistanceM.round()} m away • ${peer.relativeBearingDeg.round()}°',
                          ),
                          trailing: Chip(
                            backgroundColor: outside ? Colors.red.shade200 : Colors.green.shade200,
                            label: Text(outside ? 'outside' : 'inside'),
                          ),
                        ),
                      ),
                    );
                  },
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
  const PinwheelWidget({
    super.key,
    required this.radiusM,
    required this.peers,
  });

  final double radiusM;
  final List<SessionPeer> peers;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: PinwheelPainter(radiusM: radiusM, peers: peers),
      child: const SizedBox.expand(),
    );
  }
}

class PinwheelPainter extends CustomPainter {
  PinwheelPainter({required this.radiusM, required this.peers});

  final double radiusM;
  final List<SessionPeer> peers;

  static const _palette = [
    Color(0xFF4FC3F7),
    Color(0xFF29B6F6),
    Color(0xFF0288D1),
    Color(0xFF5C6BC0),
    Color(0xFF26A69A),
    Color(0xFF66BB6A),
    Color(0xFFFFA726),
    Color(0xFFEF5350),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outer = math.min(size.width, size.height) / 2 - 10;

    final backgroundPaint = Paint()..color = const Color(0xFFF5F9FF);
    canvas.drawCircle(center, outer, backgroundPaint);

    final ringPaint = Paint()
      ..color = const Color(0xFFB5D6FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, outer, ringPaint);

    final boundaryPixels = _distanceToPx(radiusM, outer);
    final boundaryPaint = Paint()
      ..color = const Color(0xFF66A9FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, boundaryPixels, boundaryPaint);

    final labels = ['N', 'E', 'S', 'W'];
    final labelR = outer - 18;
    for (var i = 0; i < labels.length; i++) {
      final angle = (i * 90 - 90) * math.pi / 180;
      final marker = Offset(
        center.dx + labelR * math.cos(angle),
        center.dy + labelR * math.sin(angle),
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: const TextStyle(
            color: Colors.blueGrey,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        marker - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    }

    for (var i = 0; i < peers.length; i++) {
      final peer = peers[i];
      final angle = (peer.relativeBearingDeg - 90) * math.pi / 180;
      final distancePx = _distanceToPx(peer.relativeDistanceM, outer);
      final armEnd = Offset(
        center.dx + distancePx * math.cos(angle),
        center.dy + distancePx * math.sin(angle),
      );

      final paint = Paint()
        ..color = _palette[i % _palette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = peer.outsideBoundary ? 2.4 : 1.8
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(center, armEnd, paint);

      final dotPaint = Paint()
        ..color = _palette[i % _palette.length]
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        armEnd,
        peer.outsideBoundary ? 8 : 6,
        dotPaint,
      );

      final labelOffset = Offset(
        center.dx + (distancePx + 14) * math.cos(angle),
        center.dy + (distancePx + 14) * math.sin(angle),
      );
      final labelPainter = TextPainter(
        text: TextSpan(
          text: peer.emoji,
          style: const TextStyle(fontSize: 14),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();
      labelPainter.paint(
        canvas,
        labelOffset - Offset(labelPainter.width / 2, labelPainter.height / 2),
      );
    }
  }

  double _distanceToPx(double distanceM, double maxPx) {
    final clamped = distanceM.clamp(0.0, radiusM).toDouble();
    final scale = (maxPx - 20) / radiusM;
    return 20 + clamped * scale;
  }

  @override
  bool shouldRepaint(covariant PinwheelPainter oldDelegate) {
    return oldDelegate.radiusM != radiusM || oldDelegate.peers.length != peers.length;
  }
}
