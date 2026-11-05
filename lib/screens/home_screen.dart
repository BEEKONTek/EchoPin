import 'package:echo_pin/providers/session_scope.dart';
import 'package:flutter/material.dart';
import 'session_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _startDemo(BuildContext context) async {
    final provider = SessionScope.read(context);
    try {
      await provider.createSession(
        name: 'Demo Session',
        forceSimulation: true,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error starting demo: $e')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SessionScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EchoPin'), centerTitle: true),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.location_on, size: 80, color: Colors.blue),
                const SizedBox(height: 24),
                const Text(
                  'EchoPin Demo',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'A privacy-first peer presence simulation.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.black54),
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: () => _startDemo(context),
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Start Demo', style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
