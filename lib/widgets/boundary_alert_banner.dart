import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/alert_scope.dart';
import 'package:flutter/material.dart';

/// Animates the current boundary alert in/out at the top of its parent.
/// Collapses to zero height when the queue is empty.
class BoundaryAlertBanner extends StatelessWidget {
  const BoundaryAlertBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final AlertProvider provider = AlertScope.of(context);
    final BoundaryAlert? alert = provider.current;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      transitionBuilder: (Widget child, Animation<double> animation) {
        return SizeTransition(
          sizeFactor: animation,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      child: alert == null
          ? const SizedBox.shrink()
          : _AlertCard(
              key: ValueKey<String>(alert.id),
              alert: alert,
              onDismiss: () => provider.dismiss(alert.id),
            ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({
    super.key,
    required this.alert,
    required this.onDismiss,
  });

  final BoundaryAlert alert;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final bool entering = alert.direction == CrossingDirection.entered;
    final Color color =
        entering ? Colors.teal.shade700 : Colors.orange.shade800;
    final IconData icon = entering
        ? Icons.person_add_alt_1
        : Icons.person_remove_alt_1;

    return Material(
      color: color,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: <Widget>[
              Icon(icon, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  alert.message,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
