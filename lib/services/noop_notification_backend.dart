import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/services/notification_backend.dart';

/// Silent backend for tests, CI, and platforms where OS notifications are
/// unavailable or unwanted.
class NoopNotificationBackend implements NotificationBackend {
  const NoopNotificationBackend();

  @override
  String get name => 'In-app only';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> requestPermissions() async {}

  @override
  Future<void> showBoundaryAlert(BoundaryAlert alert) async {}

  @override
  Future<void> showNotice(LocalNotice notice) async {}
}
