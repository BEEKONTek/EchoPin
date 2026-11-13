import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'key_value_store.dart';

/// OS-level secure storage:
///   - Android: EncryptedSharedPreferences
///   - iOS / macOS: Keychain
///
/// Every method swallows exceptions so that a missing platform backend (unit
/// tests, web, Linux without libsecret) degrades to a no-op rather than
/// crashing the caller.
class SecureStorageKvStore implements KeyValueStore {
  SecureStorageKvStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      // Silent; the caller treats the write as best-effort.
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {} // best effort: the key may not exist
  }
}
