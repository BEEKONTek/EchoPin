import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/widgets/pinwheel_painter.dart';
import 'package:flutter/material.dart';

import 'session_screen.dart';

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
