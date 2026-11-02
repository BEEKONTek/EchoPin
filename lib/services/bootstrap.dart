import 'package:echo_pin/services/key_value_store.dart';
import 'package:echo_pin/services/local_notification_backend.dart';
import 'package:echo_pin/services/method_channel_ble_bridge.dart';
import 'package:echo_pin/services/noop_notification_backend.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:echo_pin/services/prefs_kv_store.dart';
import 'package:echo_pin/services/secure_kv_store.dart';
import 'package:echo_pin/services/secure_store.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter/foundation.dart';

/// One-time backend selection at app startup.
///
/// Every backend is probed against its fallback. Nothing here throws — a
/// missing platform (web, Linux without libsecret, CI) degrades silently to
/// a working substitute.
class Bootstrap {
  Bootstrap._({
    required this.codec,
    required this.notifications,
    required this.usingSecureStorage,
    required this.usingRealBle,
  });

  final SessionCodec codec;
  final NotificationBackend notifications;
  final bool usingSecureStorage;
  final bool usingRealBle;

  static Future<Bootstrap> initialize() async {
    // ── 1. Secure storage (with prefs fallback) ────────────────────────────
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

    // ── 2. Session codec with per-install secret ──────────────────────────
    final String secret = await SecureStore(kv: kv).getOrCreateSecret();
    final SessionCodec codec = SessionCodec(secret: secret);

    // ── 3. OS notifications (with noop fallback) ──────────────────────────
    NotificationBackend notifications = const NoopNotificationBackend();
    try {
      final LocalNotificationBackend local = LocalNotificationBackend();
      await local.initialize();
      notifications = local;
    } catch (e) {
      debugPrint('Local notifications unavailable, using noop: $e');
    }

    // ── 4. BLE availability probe (informational only for MVP) ────────────
    // The bridge is fully implemented and native-compiled, but MeshService
    // continues to use the simulated transport until the runtime wiring
    // batch lands. Tracking availability here lets the admin panel and
    // README report the true state.
    bool usingRealBle = false;
    try {
      usingRealBle = await MethodChannelBleBridge().isAvailable();
    } catch (_) {
      usingRealBle = false;
    }

    return Bootstrap._(
      codec: codec,
      notifications: notifications,
      usingSecureStorage: usingSecure,
      usingRealBle: usingRealBle,
    );
  }
}
