import 'dart:async';

import 'package:echo_pin/services/key_value_store.dart';
import 'package:echo_pin/services/local_notification_backend.dart';
import 'package:echo_pin/services/method_channel_ble_bridge.dart';
import 'package:echo_pin/services/noop_notification_backend.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:echo_pin/services/prefs_kv_store.dart';
import 'package:echo_pin/services/secure_kv_store.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter/foundation.dart';

/// `--dart-define=ECHOPIN_FORCE_SIM=true` skips the BLE probe entirely.
const bool kForceSimulation = bool.fromEnvironment('ECHOPIN_FORCE_SIM');

/// One-time backend selection at app startup.
///
/// Every backend is probed against its fallback, and every probe has a
/// timeout. Nothing here throws and nothing here shows UI: a missing or hung
/// platform (web, Linux without libsecret, CI) degrades to a working
/// substitute and the first frame is never held hostage.
class Bootstrap {
  Bootstrap._({
    required this.codec,
    required this.kv,
    required this.notifications,
    required this.usingSecureStorage,
    required this.usingRealBle,
  });

  /// Fully in-memory/fallback configuration for widget tests.
  @visibleForTesting
  factory Bootstrap.forTesting({
    required KeyValueStore kv,
    SessionCodec? codec,
    NotificationBackend notifications = const NoopNotificationBackend(),
    bool usingSecureStorage = false,
    bool usingRealBle = false,
  }) {
    return Bootstrap._(
      codec: codec ?? SessionCodec(),
      kv: kv,
      notifications: notifications,
      usingSecureStorage: usingSecureStorage,
      usingRealBle: usingRealBle,
    );
  }

  static const Duration _probeTimeout = Duration(seconds: 3);

  final SessionCodec codec;

  /// The store selected for secrets (install secret, admin PIN hash).
  final KeyValueStore kv;
  final NotificationBackend notifications;
  final bool usingSecureStorage;
  final bool usingRealBle;

  static String get platformLabel {
    if (kIsWeb) return 'Web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      case TargetPlatform.fuchsia:
        return 'Fuchsia';
    }
  }

  static Future<Bootstrap> initialize() async {
    // ── 1. Secure storage (with prefs fallback) ──────────────────────────
    bool usingSecure = false;
    KeyValueStore kv = PrefsKvStore();
    try {
      final SecureStorageKvStore secure = SecureStorageKvStore();
      final String? echo = await () async {
        await secure.write('__echopin_ping__', 'ok');
        final String? value = await secure.read('__echopin_ping__');
        await secure.delete('__echopin_ping__');
        return value;
      }().timeout(_probeTimeout);
      if (echo == 'ok') {
        kv = secure;
        usingSecure = true;
      }
    } catch (e) {
      debugPrint('Secure storage unavailable, using prefs: $e');
    }

    // ── 2. Session codec ─────────────────────────────────────────────────
    // Codes are keyless (they carry their own secret), so every install
    // reads every other install's codes.
    final SessionCodec codec = SessionCodec();

    // ── 3. OS notifications (with noop fallback) ─────────────────────────
    NotificationBackend notifications = const NoopNotificationBackend();
    try {
      final LocalNotificationBackend local = LocalNotificationBackend();
      await local.initialize().timeout(_probeTimeout);
      notifications = local;
    } catch (e) {
      debugPrint('Local notifications unavailable, using in-app only: $e');
    }

    // ── 4. Native BLE bridge probe ───────────────────────────────────────
    bool usingRealBle = false;
    if (!kForceSimulation && !kIsWeb) {
      try {
        usingRealBle = await MethodChannelBleBridge().isAvailable().timeout(
          _probeTimeout,
        );
      } catch (_) {
        usingRealBle = false;
      }
    }

    return Bootstrap._(
      codec: codec,
      kv: kv,
      notifications: notifications,
      usingSecureStorage: usingSecure,
      usingRealBle: usingRealBle,
    );
  }
}
