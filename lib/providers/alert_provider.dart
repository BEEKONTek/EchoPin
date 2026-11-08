import 'dart:async';

import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:flutter/foundation.dart';

/// Throttles crossings per peer and forwards the survivors to
/// [NotificationService], which handles both the in-app queue and the OS
/// dispatch. Also fires haptics.
class AlertProvider extends ChangeNotifier {
  AlertProvider({
    required this.notifications,
    required this.haptics,
    this.throttle = const Duration(seconds: 5),
  }) {
    notifications.addListener(_onNotifications);
  }

  final NotificationService notifications;
  final HapticService haptics;
  final Duration throttle;
  final Map<String, DateTime> _lastAlertByPeer = <String, DateTime>{};

  List<BoundaryAlert> get active => notifications.active;
  BoundaryAlert? get current => notifications.current;

  void handleCrossing(BoundaryAlert alert) {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastAlertByPeer[alert.peerId];
    if (last != null && now.difference(last) < throttle) return;
    _lastAlertByPeer[alert.peerId] = now;

    notifications.push(alert);
    unawaited(_fireHaptic(alert));
  }

  /// A ping arrived: OS notification (urgent for SOS) plus haptics. The
  /// in-app tray is driven by the session's ping list, not by this queue.
  ///
  /// Pings bypass the boundary-alert switch: muting boundary chatter must
  /// never silence an SOS.
  void handlePing(IncomingPing ping) {
    final bool sos = ping.kind == PingKind.sos;
    final String note = ping.note == null ? '' : ' “${ping.note}”';
    // Check-ins respect the OS-notification switch; an SOS always reaches
    // the lock screen.
    if (sos || notifications.osNotificationsEnabled()) {
      unawaited(
        notifications.backend.showNotice(
          LocalNotice(
            id: '${ping.fromId}:${ping.id}'.hashCode & 0x7FFFFFFF,
            title: sos
                ? 'SOS from ${ping.fromName}'
                : '${ping.fromName} is checking in',
            body: sos
                ? '${ping.fromName} needs help.$note Open EchoPin to respond.'
                : 'Are you OK?$note Tap to answer.',
            urgency: sos ? NoticeUrgency.critical : NoticeUrgency.high,
          ),
        ),
      );
    }
    unawaited(sos ? haptics.sos() : haptics.medium());
  }

  void dismiss(String id) => notifications.dismiss(id);
  void dismissAll() => notifications.dismissAll();

  Future<void> _fireHaptic(BoundaryAlert alert) {
    return alert.direction == CrossingDirection.entered
        ? haptics.light()
        : haptics.medium();
  }

  void _onNotifications() => notifyListeners();

  @override
  void dispose() {
    notifications.removeListener(_onNotifications);
    super.dispose();
  }
}
