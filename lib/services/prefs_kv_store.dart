import 'package:shared_preferences/shared_preferences.dart';

import 'key_value_store.dart';

/// Plain-text KV backed by [SharedPreferences].
///
/// Used in tests, as a fallback when secure storage is unavailable (web,
/// Linux desktop without libsecret), and as the migration source for
/// previously-installed clients that stored secrets in prefs.
class PrefsKvStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}
