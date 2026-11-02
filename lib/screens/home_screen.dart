import 'dart:math';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/widgets/pinwheel_painter.dart';
import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final meshService = MeshService();

    return Scaffold(
      appBar: AppBar(
        title: const Text('EchoPin'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.location_on, size: 72, color: Colors.blue),
            const SizedBox(height: 24),
            const Text(
              'Privacy-first peer presence',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'Create a session and see nearby peers without exposing raw locations.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.black54),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  final session = meshService.createSession('Demo Session');
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SessionScreen(session: session),
                    ),
                  );
                },
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Create session'),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  final session = meshService.joinSession(
                    sessionName: 'Joined Session',
                    sessionId: 'session-join-demo',
                  );
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SessionScreen(session: session),
                    ),
                  );
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Join via QR'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.session});

  final Session session;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late double _boundaryRadius;

  @override
  void initState() {
    super.initState();
    _boundaryRadius = widget.session.boundaryRadiusMeters;
  }

  @override
  Widget build(BuildContext context) {
    final peers = widget.session.peers;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.name),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            SizedBox(
              height: 320,
              child: CustomPaint(
                painter: PinwheelPainter(
                  peers: peers.map((peer) => PeerPresence(
                    id: peer.id,
                    label: peer.label,
                    bearingDegrees: peer.bearingDegrees,
                    distanceMeters: peer.distanceMeters,
                  )).toList(),
                  boundaryRadius: 130,
                  centerRadius: 18,
                ),
                size: const Size(320, 320),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Boundary radius',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            Slider(
              value: _boundaryRadius,
              min: 50,
              max: 500,
              divisions: 45,
              label: '${_boundaryRadius.round()}m',
              onChanged: (value) {
                setState(() {
                  _boundaryRadius = value;
                });
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: peers.length,
                itemBuilder: (context, index) {
                  final peer = peers[index];
                  final isInside = peer.distanceMeters <= _boundaryRadius;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: const Icon(Icons.person_pin_circle_rounded),
                      title: Text(peer.label),
                      subtitle: Text(
                        'Bearing ${peer.bearingDegrees.toStringAsFixed(0)}° • ${peer.distanceMeters.round()}m away',
                      ),
                      trailing: Icon(
                        isInside ? Icons.check_circle : Icons.warning_amber_rounded,
                        color: isInside ? Colors.green : Colors.orange,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
