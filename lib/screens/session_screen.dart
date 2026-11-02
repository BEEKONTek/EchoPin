import 'package:echo_pin/models/session.dart';
import 'package:flutter/material.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.session});

  final Session session;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  double _boundaryRadius = 150;

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
            const Text(
              'Nearby peers',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  for (final peer in peers)
                    Positioned(
                      left: 150 + (cos((peer.bearingDegrees - 90) * pi / 180) * (peer.distanceMeters / 4.5)),
                      top: 150 + (sin((peer.bearingDegrees - 90) * pi / 180) * (peer.distanceMeters / 4.5)),
                      child: Column(
                        children: <Widget>[
                          Container(
                            width: 14,
                            height: 14,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.blue,
                            ),
                          ),
                          Text(
                            peer.label,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  const Positioned(
                    child: Icon(Icons.person_pin_circle, size: 32, color: Colors.black),
                  ),
                ],
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
