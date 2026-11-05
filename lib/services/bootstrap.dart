import 'package:echo_pin/services/key_value_store.dart';
import 'package:echo_pin/services/local_notification_backend.dart';
import 'package:echo_pin/services/noop_notification_backend.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:echo_pin/services/prefs_kv_store.dart';
import 'package:echo_pin/services/secure_kv_store.dart';
import 'package:echo_pin/services/secure_store.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter/foundation.dart';

class Bootstrap {
  Bootstrap._({
    required this.codec,
    required this.notifications,
    required this.usingSecureStorage,
  });

  final SessionCodec codec;
  final NotificationBackend notifications;
  final bool usingSecureStorage;

  static Future<Bootstrap> initialize() async {
    bool usingSecure = false;
    KeyValueStore kv = PrefsKvStore();
    try {
      final SecureStorageKvStore secure = SecureStorageKvStore();
      await secure.write('__echopin_ping__', 'ok');
      final String? echo = await secure.read('__echopin_ping__');
      await secure.delete('__echopin_ping__');
      if (echo == 'ok') {
        kv = secure;
        usingSecure = true;
      }
    } catch (e) {
      debugPrint('Secure storage unavailable, using prefs: $e');
    }

    final String secret = await SecureStore(kv: kv).getOrCreateSecret();
    final SessionCodec codec = SessionCodec(secret: secret);

    NotificationBackend notifications = const NoopNotificationBackend();
    try {
      final LocalNotificationBackend local = LocalNotificationBackend();
      await local.initialize();
      notifications = local;
    } catch (e) {
      debugPrint('Local notifications unavailable, using noop: $e');
    }

    return Bootstrap._(
      codec: codec,
      notifications: notifications,
      usingSecureStorage: usingSecure,
    );
  }
}
