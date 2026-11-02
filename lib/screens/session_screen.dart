import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/widgets/pinwheel_painter.dart';
import 'package:flutter/material.dart';

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
            const SizedBox(height: 8),
            SizedBox(
              height: 300,
              child: CustomPaint(
                painter: PinwheelPainter(
                  peers: peers,
                  boundaryRadius: _boundaryRadius,
                  centerRadius: 18,
                ),
                child: Container(),
              ),
            ),
            const SizedBox(height: 20),
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
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.people_alt_rounded),
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
