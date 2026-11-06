import 'dart:convert';

import 'package:echo_pin/models/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists [AppSettings] in SharedPreferences (available on every Flutter
/// platform). Settings are not secret, so plain prefs is the right store.
class SettingsService {
  static const String _kSettings = 'echo_pin.settings_v1';

  Future<AppSettings> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_kSettings);
      if (raw == null || raw.isEmpty) return const AppSettings();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const AppSettings();
      return AppSettings.fromJson(decoded);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSettings, jsonEncode(settings.toJson()));
  }

  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSettings);
  }
}
