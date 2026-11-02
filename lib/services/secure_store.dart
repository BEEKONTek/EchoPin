import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'key_value_store.dart';
import 'prefs_kv_store.dart';

/// Manages the per-install 32-byte (64 hex char) secret used as the HMAC key
/// for [SessionCodec].
///
/// Default backend is [PrefsKvStore] so tests and Linux desktop work without
/// native config. Production wiring (Bootstrap, later batch) passes a
/// [SecureStorageKvStore] to get OS-level protection.
class SecureStore {
  SecureStore({KeyValueStore? kv}) : _kv = kv ?? PrefsKvStore();

  static const String _kSecret = 'echo_pin.install_secret_v1';
  static const int _minSecretLength = 32;

  final KeyValueStore _kv;

  /// Returns the existing secret, migrates one from legacy SharedPreferences
  /// if switching backends, or generates and stores a fresh one.
  Future<String> getOrCreateSecret() async {
    final String? existing = await _kv.read(_kSecret);
    if (existing != null && existing.length >= _minSecretLength) {
      return existing;
    }

    // One-time migration. Only meaningful when the current backend is not
    // plain prefs — otherwise the read above would already have found it.
    if (_kv is! PrefsKvStore) {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? legacy = prefs.getString(_kSecret);
      if (legacy != null && legacy.length >= _minSecretLength) {
        await _kv.write(_kSecret, legacy);
        await prefs.remove(_kSecret);
        return legacy;
      }
    }

    final String fresh = _randomHex(32);
    await _kv.write(_kSecret, fresh);
    return fresh;
  }

  String _randomHex(int byteLength) {
    final math.Random rng = math.Random.secure();
    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < byteLength; i++) {
      buf.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
