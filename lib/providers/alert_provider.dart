import 'dart:async';

import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/services/haptic_service.dart';
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
