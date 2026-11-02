import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:flutter/material.dart';

import 'session_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _openSession(
    BuildContext context, {
    required Future<void> Function(SessionProvider) start,
  }) async {
    final SessionProvider provider = SessionScope.read(context);
    try {
      await start(provider);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not start session: $e')));
      return;
    }
    if (!context.mounted) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SessionScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EchoPin'), centerTitle: true),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.location_on, size: 72, color: Colors.blue),
              const SizedBox(height: 24),
              const Text(
                'Privacy-first peer presence',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'Create a session and see nearby peers without exposing raw '
                'locations.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.black54),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _openSession(
                    context,
                    start: (SessionProvider p) =>
                        p.createSession(name: 'Demo Session'),
                  ),
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Create session'),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _openSession(
                    context,
                    start: (SessionProvider p) =>
                        p.joinSession(sessionName: 'Joined Session'),
                  ),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Join via QR'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
