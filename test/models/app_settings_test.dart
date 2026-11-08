import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('JSON round-trip', () {
    const AppSettings s = AppSettings(
      defaultBoundaryRadiusMeters: 220,
      noiseSigmaMeters: 12,
      alertsEnabled: false,
      osNotificationsEnabled: false,
      hapticsEnabled: false,
      forceSimulation: true,
    );
    expect(AppSettings.fromJson(s.toJson()), s);
  });

  test('fromJson tolerates missing, mistyped and out-of-range fields', () {
    final AppSettings s = AppSettings.fromJson(<String, dynamic>{
      'defaultBoundaryRadiusMeters': 9999,
      'noiseSigmaMeters': 'loud',
      'alertsEnabled': 'yes',
    });
    expect(s.defaultBoundaryRadiusMeters, AppSettings.maxRadius);
    expect(s.noiseSigmaMeters, const AppSettings().noiseSigmaMeters);
    expect(s.alertsEnabled, isTrue);
  });

  group('SettingsProvider', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('persists updates and reloads them', () async {
      final SettingsProvider a = SettingsProvider(service: SettingsService());
      await a.update(const AppSettings(noiseSigmaMeters: 20));
      final SettingsProvider b = SettingsProvider(service: SettingsService());
      await b.load();
      expect(b.value.noiseSigmaMeters, 20);
    });

    test('reset restores defaults', () async {
      final SettingsProvider p = SettingsProvider(service: SettingsService());
      await p.update(const AppSettings(forceSimulation: true));
      await p.reset();
      expect(p.value, const AppSettings());
    });

    test('corrupted blob loads defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'echo_pin.settings_v1': '{not json',
      });
      final SettingsProvider p = SettingsProvider(service: SettingsService());
      await p.load();
      expect(p.value, const AppSettings());
    });
  });
}
