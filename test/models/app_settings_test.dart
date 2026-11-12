import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('JSON round-trip', () {
    const AppSettings s = AppSettings(
      defaultBoundaryRadiusMeters: 70,
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
    // Past the 100 m radar: a value from the old 500 m scale, so the
    // default comes back rather than the very edge.
    expect(
      s.defaultBoundaryRadiusMeters,
      const AppSettings().defaultBoundaryRadiusMeters,
    );
    expect(s.noiseSigmaMeters, const AppSettings().noiseSigmaMeters);
    expect(s.alertsEnabled, isTrue);
  });

  test('a boundary saved on the old 500 m radar moves onto the 100 m one', () {
    expect(
      AppSettings.fromJson(<String, dynamic>{
        'defaultBoundaryRadiusMeters': 150,
      }).defaultBoundaryRadiusMeters,
      50,
    );
    expect(
      AppSettings.fromJson(<String, dynamic>{
        'defaultBoundaryRadiusMeters': 80,
      }).defaultBoundaryRadiusMeters,
      80,
    );
    expect(
      AppSettings.fromJson(<String, dynamic>{
        'defaultBoundaryRadiusMeters': 2,
      }).defaultBoundaryRadiusMeters,
      AppSettings.minRadius,
    );
    expect(AppSettings.maxRadius, 100);
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
