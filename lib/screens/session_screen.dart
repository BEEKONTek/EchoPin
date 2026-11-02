import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:echo_pin/widgets/boundary_alert_banner.dart';
import 'package:echo_pin/widgets/pinwheel_painter.dart';
import 'package:flutter/material.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  double? _dragRadius;

  @override
  Widget build(BuildContext context) {
    final SessionProvider provider = SessionScope.of(context);
    final Session? session = provider.session;

    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Session')),
        body: const Center(child: Text('No active session.')),
      );
    }

    final double displayRadius =
        _dragRadius ?? session.boundaryRadiusMeters;

    return Scaffold(
      appBar: AppBar(
        title: Text(session.name),
        actions: <Widget>[
          IconButton(
            tooltip: 'Leave session',
            icon: const Icon(Icons.exit_to_app),
            onPressed: () {
              provider.leaveSession();
              Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            const BoundaryAlertBanner(),
            SizedBox(
              height: 280,
              child: CustomPaint(
                painter: PinwheelPainter(
                  peers: session.peers,
                  boundaryRadius: session.boundaryRadiusMeters,
                  centerRadius: 18,
                ),
                child: Container(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Boundary radius: ${session.boundaryRadiusMeters.round()} m',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            Slider(
              value: displayRadius,
              min: 50,
              max: 500,
              divisions: 45,
              label: '${displayRadius.round()}m',
              onChanged: (double value) {
                setState(() => _dragRadius = value);
                provider.updateBoundaryRadius(value);
              },
              onChangeEnd: (_) => setState(() => _dragRadius = null),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: session.peers.length,
                itemBuilder: (BuildContext context, int index) {
                  final PeerPresence peer = session.peers[index];
                  final bool inside =
                      peer.distanceMeters <= session.boundaryRadiusMeters;
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.people_alt_rounded),
                      title: Text(peer.label),
                      subtitle: Text(
                        'Bearing ${peer.bearingDegrees.toStringAsFixed(0)}° · '
                        '${peer.distanceMeters.round()} m away',
                      ),
                      trailing: Icon(
                        inside
                            ? Icons.check_circle
                            : Icons.warning_amber_rounded,
                        color: inside ? Colors.green : Colors.orange,
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
