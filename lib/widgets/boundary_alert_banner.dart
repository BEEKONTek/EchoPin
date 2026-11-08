import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/alert_scope.dart';
import 'package:echo_pin/ui/theme.dart';
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
  const _AlertCard({super.key, required this.alert, required this.onDismiss});

  final BoundaryAlert alert;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool entering = alert.direction == CrossingDirection.entered;
    // Leaving the boundary is the one worth noticing; entering is calm.
    final Color bg = entering
        ? scheme.secondaryContainer
        : scheme.errorContainer;
    final Color fg = entering
        ? scheme.onSecondaryContainer
        : scheme.onErrorContainer;
    final IconData icon = entering
        ? Icons.person_add_alt_1
        : Icons.person_remove_alt_1;

    return Padding(
      padding: const EdgeInsets.only(bottom: EchoTheme.trayGap),
      child: Semantics(
        liveRegion: true,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(EchoTheme.radius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
            child: Row(
              children: <Widget>[
                Icon(icon, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    alert.message,
                    style: TextStyle(
                      color: fg,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  icon: Icon(Icons.close, size: 18, color: fg),
                  onPressed: onDismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
