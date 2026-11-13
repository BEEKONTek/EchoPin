import 'package:flutter/foundation.dart';

enum TraySeverity { info, warning, critical }

/// What the tray's button does.
enum TrayAction {
  none,
  enableBluetooth,
  allowBluetooth,
  retryBluetooth,
  openSettings,
}

/// Kinds of status tray, so the UI can pick an icon without string checks.
enum TrayKind {
  bluetoothOff,
  bluetoothDenied,
  bluetoothBlocked,
  bluetoothFailed,
  noWifi,
  wifiFailed,
  offline,
  security,
  sessionFull,
  ended,
}

/// One animated status card ("Bluetooth is off. Turn on").
@immutable
class StatusTray {
  const StatusTray({
    required this.id,
    required this.kind,
    required this.severity,
    required this.title,
    required this.message,
    this.action = TrayAction.none,
    this.actionLabel,
    this.dismissible = true,
  });

  /// Stable identity, so animations track the same tray across rebuilds.
  final String id;
  final TrayKind kind;
  final TraySeverity severity;
  final String title;
  final String message;
  final TrayAction action;
  final String? actionLabel;
  final bool dismissible;

  @override
  bool operator ==(Object other) =>
      other is StatusTray &&
      other.id == id &&
      other.title == title &&
      other.message == message &&
      other.action == action;

  @override
  int get hashCode => Object.hash(id, title, message, action);
}
