import 'package:echo_pin/models/boundary_alert.dart';

/// Abstract OS-notification sink.
///
/// Backends must be safe to call repeatedly, safe to call before [initialize]
/// completes, and must swallow platform errors. A test backend or a no-op
/// fallback should be usable without any native configuration.
abstract class NotificationBackend {
  Future<void> initialize();
  Future<void> showBoundaryAlert(BoundaryAlert alert);
}
