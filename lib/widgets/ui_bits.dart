import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:flutter/material.dart';

/// A rounded surface in EchoPin's tray language.
class Tray extends StatelessWidget {
  const Tray({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: t.textTheme.labelMedium?.copyWith(
                letterSpacing: 1.1,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Small coloured pill for statuses, roles and severities.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme s = Theme.of(context).colorScheme;
    final Color c = color ?? s.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Inline, animated error line under a form.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.message, {super.key});
  final String? message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme s = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: EchoTheme.fast,
      curve: EchoTheme.enter,
      child: message == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.error_outline, size: 18, color: s.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(message!, style: TextStyle(color: s.error)),
                  ),
                ],
              ),
            ),
    );
  }
}

/// One-line explanation tray (info, warning or success).
class NoticeTray extends StatelessWidget {
  const NoticeTray({
    super.key,
    required this.icon,
    required this.text,
    this.color,
  });
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme s = Theme.of(context).colorScheme;
    final Color c = color ?? s.primary;
    return Tray(
      color: c.withValues(alpha: 0.08),
      child: Row(
        children: <Widget>[
          Icon(icon, color: c),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// The sentence to show for any thrown error.
String errorText(Object e) => asEchoError(e).message;

Color severityColor(BuildContext context, String? severity) {
  final ColorScheme s = Theme.of(context).colorScheme;
  switch (severity) {
    case 'critical':
      return EchoTheme.sos;
    case 'high':
      return EchoTheme.checkIn;
    case 'low':
      return s.outline;
    default:
      return s.primary;
  }
}

Color statusColor(BuildContext context, String? status) {
  final ColorScheme s = Theme.of(context).colorScheme;
  switch (status) {
    case 'open':
    case 'failed':
    case 'disabled':
    case 'error':
      return s.error;
    case 'investigating':
    case 'running':
    case 'pending':
    case 'warning':
      return EchoTheme.checkIn;
    case 'resolved':
    case 'ok':
    case 'active':
      return Colors.green.shade600;
    default:
      return s.outline;
  }
}
