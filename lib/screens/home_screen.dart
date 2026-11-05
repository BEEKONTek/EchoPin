import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:flutter/material.dart';
import 'session_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _codeController = TextEditingController();

  @override
  void dispose() { _codeController.dispose(); super.dispose(); }

  Future<void> _start(BuildContext context, {required bool isJoin, bool forceSim = false}) async {
    final provider = SessionScope.read(context);
    try {
      if (isJoin) {
        if (_codeController.text.trim().isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a code')));
          return;
        }
        await provider.joinSession(sessionName: 'Joined Session', sessionId: _codeController.text.trim().toUpperCase(), forceSimulation: forceSim);
      } else {
        await provider.createSession(name: 'Host Session', forceSimulation: forceSim);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SessionScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EchoPin'), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: <Widget>[
              const Icon(Icons.location_on, size: 64, color: Colors.blue),
              const SizedBox(height: 16),
              const Text('Privacy-first presence', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: () => _start(context, isJoin: false),
                icon: const Icon(Icons.bluetooth),
                label: const Text('Create Live Session (Host)'),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 24),
              TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Enter Session Code (to Join)', border: OutlineInputBorder(), hintText: 'ECHO-XXXX-XXXX-YY'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: () => _start(context, isJoin: true),
                icon: const Icon(Icons.login),
                label: const Text('Join Live Session (Peer)'),
              ),
              const SizedBox(height: 32),
              TextButton.icon(
                onPressed: () => _start(context, isJoin: false, forceSim: true),
                icon: const Icon(Icons.play_circle_outline, color: Colors.green),
                label: const Text('Presenter Safety Net (Demo Mode)', style: TextStyle(color: Colors.green)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
