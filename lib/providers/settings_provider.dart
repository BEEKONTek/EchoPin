import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/services/settings_service.dart';
import 'package:flutter/foundation.dart';

/// Holds the live [AppSettings]. Services read through callbacks
/// (`() => settings.value.x`) so changes apply without re-wiring.
class SettingsProvider extends ChangeNotifier {
  SettingsProvider({SettingsService? service, AppSettings? initial})
    : _service = service ?? SettingsService(),
      _value = initial ?? const AppSettings();

  final SettingsService _service;
  AppSettings _value;

  AppSettings get value => _value;

  Future<void> load() async {
    _value = await _service.load();
    notifyListeners();
  }

  Future<void> update(AppSettings next) async {
    final AppSettings clean = next.sanitized();
    if (clean == _value) return;
    _value = clean;
    notifyListeners();
    await _service.save(clean);
  }

  Future<void> reset() async {
    _value = const AppSettings();
    notifyListeners();
    await _service.clear();
  }
}
