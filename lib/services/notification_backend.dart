import 'package:echo_pin/models/boundary_alert.dart';

enum NoticeUrgency { normal, high, critical }

/// A generic OS notification (pings, SOS).
class LocalNotice {
  const LocalNotice({
    required this.id,
    required this.title,
    required this.body,
    this.urgency = NoticeUrgency.normal,
  });

  final int id;
  final String title;
  final String body;
  final NoticeUrgency urgency;
}

/// Abstract OS-notification sink.
///
/// Backends must be safe to call repeatedly, safe to call before [initialize]
/// completes, and must swallow platform errors. A test backend or a no-op
/// fallback should be usable without any native configuration.
abstract class NotificationBackend {
  /// Human-readable backend name for diagnostics.
  String get name;

  /// Sets up the plugin. Must not show any UI, because it runs before the
  /// first frame.
  Future<void> initialize();

  /// Asks the OS for permission to post. Called after the first frame so a
  /// system dialog never blocks startup.
  Future<void> requestPermissions();

  Future<void> showBoundaryAlert(BoundaryAlert alert);

  Future<void> showNotice(LocalNotice notice);
}
