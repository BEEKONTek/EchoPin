import 'package:echo_pin/models/status_tray.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:flutter/material.dart';

/// A single status card: "Bluetooth is off · Turn on".
class StatusTrayView extends StatelessWidget {
  const StatusTrayView({
    super.key,
    required this.tray,
    this.onAction,
    this.onDismiss,
  });

  final StatusTray tray;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  static IconData iconFor(TrayKind kind) {
    switch (kind) {
      case TrayKind.bluetoothOff:
        return Icons.bluetooth_disabled;
      case TrayKind.bluetoothDenied:
      case TrayKind.bluetoothBlocked:
        return Icons.bluetooth_audio_outlined;
      case TrayKind.bluetoothFailed:
        return Icons.bluetooth_searching;
      case TrayKind.noWifi:
        return Icons.wifi_off;
      case TrayKind.wifiFailed:
        return Icons.wifi_find;
      case TrayKind.offline:
        return Icons.portable_wifi_off;
      case TrayKind.security:
        return Icons.gpp_maybe_outlined;
      case TrayKind.sessionFull:
        return Icons.groups_outlined;
      case TrayKind.ended:
        return Icons.timer_off_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg) = switch (tray.severity) {
      TraySeverity.critical => (scheme.errorContainer, scheme.onErrorContainer),
      TraySeverity.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      TraySeverity.info => (
        scheme.surfaceContainerHigh,
        scheme.onSurfaceVariant,
      ),
    };
    return Semantics(
      container: true,
      liveRegion: tray.severity == TraySeverity.critical,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(EchoTheme.radius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Row(
            children: <Widget>[
              Icon(iconFor(tray.kind), color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      tray.title,
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tray.message,
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.85),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (tray.actionLabel != null && onAction != null)
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(foregroundColor: fg),
                  child: Text(tray.actionLabel!),
                ),
              if (tray.dismissible && onDismiss != null)
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close, size: 18, color: fg),
                  onPressed: onDismiss,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
