import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Fires OS-level notifications for boundary crossings.
///
/// If the plugin cannot initialize (missing platform support, denied
/// permissions, Linux without libnotify), [_available] stays false and every
/// subsequent call becomes a no-op — no exceptions escape.
class LocalNotificationBackend implements NotificationBackend {
  LocalNotificationBackend({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const String _channelId = 'echo_pin_boundary';
  static const String _channelName = 'Boundary alerts';
  static const String _channelDescription =
      'Notifies when peers enter or leave your session boundary';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _available = false;

  @override
  Future<void> initialize() async {
    if (_available) return;
    try {
      const AndroidInitializationSettings android =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const DarwinInitializationSettings ios = DarwinInitializationSettings();
      const InitializationSettings settings = InitializationSettings(
        android: android,
        iOS: ios,
      );
      await _plugin.initialize(settings);

      final AndroidFlutterLocalNotificationsPlugin? androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImpl != null) {
        const AndroidNotificationChannel channel = AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.high,
        );
        await androidImpl.createNotificationChannel(channel);
        await androidImpl.requestNotificationsPermission();
      }

      final IOSFlutterLocalNotificationsPlugin? iosImpl = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iosImpl != null) {
        await iosImpl.requestPermissions(alert: true, badge: true, sound: true);
      }

      _available = true;
    } catch (_) {
      _available = false;
    }
  }

  @override
  Future<void> showBoundaryAlert(BoundaryAlert alert) async {
    if (!_available) return;
    try {
      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          );
      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails();
      const NotificationDetails details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final String title = alert.direction == CrossingDirection.entered
          ? 'Peer entered boundary'
          : 'Peer left boundary';
      await _plugin.show(
        alert.id.hashCode & 0x7FFFFFFF,
        title,
        alert.message,
        details,
      );
    } catch (_) {
      // Best-effort: if a single show() fails, keep the channel alive.
    }
  }
}
