import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// OS notifications for boundary crossings and pings on Android, iOS,
/// macOS, Linux and Windows. The web uses in-app alerts only.
///
/// If the plugin cannot initialize (no notification daemon, unsupported
/// platform), [initialize] throws so `Bootstrap` falls back to in-app only;
/// after a successful start every call is best-effort and never throws.
class LocalNotificationBackend implements NotificationBackend {
  LocalNotificationBackend({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const String _boundaryChannel = 'echo_pin_boundary';
  static const String _pingChannel = 'echo_pin_pings';

  static bool get isSupportedPlatform {
    // The web plugin fails to initialise without a dedicated service worker
    // (LateInitializationError); in-app alerts cover the web demo instead.
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  final FlutterLocalNotificationsPlugin _plugin;
  bool _available = false;

  @override
  String get name => _available ? 'OS notifications' : 'In-app only';

  @override
  Future<void> initialize() async {
    if (_available) return;
    if (!isSupportedPlatform) {
      throw UnsupportedError('No OS notification support on this platform');
    }
    // Permission prompts are deferred to requestPermissions() so nothing
    // blocks the first frame.
    const DarwinInitializationSettings darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const InitializationSettings settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: darwin,
      macOS: darwin,
      linux: LinuxInitializationSettings(defaultActionName: 'Open EchoPin'),
      windows: WindowsInitializationSettings(
        appName: 'EchoPin',
        appUserModelId: 'BEEKONTek.EchoPin',
        guid: '6e3f0a17-2c4b-4d8e-9a51-7b0c3e2d1f46',
      ),
    );
    final bool? ok = await _plugin.initialize(settings: settings);
    if (ok == false) throw StateError('Notification plugin refused to start');

    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _boundaryChannel,
          'Boundary alerts',
          description: 'When people enter or leave your session boundary',
          importance: Importance.high,
        ),
      );
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          _pingChannel,
          'Pings and SOS',
          description: 'Check-ins and emergency pings from your session',
          importance: Importance.max,
        ),
      );
    }
    _available = true;
  }

  @override
  Future<void> requestPermissions() async {
    if (!_available) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {
      // Denied or unsupported: the in-app banner still works.
    }
  }

  @override
  Future<void> showBoundaryAlert(BoundaryAlert alert) {
    return showNotice(
      LocalNotice(
        id: alert.id.hashCode & 0x7FFFFFFF,
        title: alert.direction == CrossingDirection.entered
            ? 'Peer entered boundary'
            : 'Peer left boundary',
        body: alert.message,
        urgency: NoticeUrgency.high,
      ),
    );
  }

  @override
  Future<void> showNotice(LocalNotice notice) async {
    if (!_available) return;
    final bool critical = notice.urgency == NoticeUrgency.critical;
    final bool ping = notice.urgency != NoticeUrgency.normal;
    try {
      await _plugin.show(
        id: notice.id,
        title: notice.title,
        body: notice.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            ping ? _pingChannel : _boundaryChannel,
            ping ? 'Pings and SOS' : 'Boundary alerts',
            importance: critical ? Importance.max : Importance.high,
            priority: critical ? Priority.max : Priority.high,
            category: critical
                ? AndroidNotificationCategory.alarm
                : AndroidNotificationCategory.message,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(presentSound: true),
          macOS: const DarwinNotificationDetails(presentSound: true),
          linux: LinuxNotificationDetails(
            urgency: critical
                ? LinuxNotificationUrgency.critical
                : LinuxNotificationUrgency.normal,
          ),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } catch (_) {
      // Best-effort: one failed show() must not break the channel.
    }
  }
}
