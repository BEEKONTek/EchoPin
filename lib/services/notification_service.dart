import 'dart:async';

import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/services/noop_notification_backend.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:flutter/foundation.dart';

/// In-app notification queue + OS dispatch.
///
/// Holds at most [_maxActive] alerts for the UI banner to read. Regardless of
/// how many alerts are queued, every push is forwarded to the [backend] when
/// both [alertsEnabled] and [osNotificationsEnabled] return true.
class NotificationService extends ChangeNotifier {
  NotificationService({
    required this.alertsEnabled,
    bool Function()? osNotificationsEnabled,
    NotificationBackend? backend,
  }) : osNotificationsEnabled = osNotificationsEnabled ?? _always,
       backend = backend ?? const NoopNotificationBackend();

  static bool _always() => true;

  static const int _maxActive = 3;

  final NotificationBackend backend;
  final bool Function() alertsEnabled;

  /// Gates only the OS dispatch; the in-app banner still shows.
  final bool Function() osNotificationsEnabled;
  final List<BoundaryAlert> _active = <BoundaryAlert>[];

  List<BoundaryAlert> get active => List<BoundaryAlert>.unmodifiable(_active);
  BoundaryAlert? get current => _active.isEmpty ? null : _active.first;

  void push(BoundaryAlert alert) {
    if (!alertsEnabled()) return;
    _active.removeWhere((BoundaryAlert a) => a.id == alert.id);
    _active.insert(0, alert);
    if (_active.length > _maxActive) {
      _active.removeRange(_maxActive, _active.length);
    }
    if (osNotificationsEnabled()) unawaited(backend.showBoundaryAlert(alert));
    notifyListeners();
  }

  void dismiss(String id) {
    final int before = _active.length;
    _active.removeWhere((BoundaryAlert a) => a.id == id);
    if (_active.length != before) notifyListeners();
  }

  void dismissAll() {
    if (_active.isEmpty) return;
    _active.clear();
    notifyListeners();
  }
}
