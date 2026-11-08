import 'package:flutter/foundation.dart';

/// User/admin-tunable runtime settings. Persisted as JSON by
/// `SettingsService`; never contains peer or location data.
@immutable
class AppSettings {
  const AppSettings({
    this.defaultBoundaryRadiusMeters = 150,
    this.noiseSigmaMeters = 7,
    this.alertsEnabled = true,
    this.osNotificationsEnabled = true,
    this.hapticsEnabled = true,
    this.forceSimulation = false,
    this.displayName = '',
    this.bluetoothEnabled = true,
    this.wifiEnabled = true,
  });

  static const double minRadius = 50;
  static const double maxRadius = 500;
  static const double minNoise = 0;
  static const double maxNoise = 50;

  /// Boundary radius applied to newly created / joined sessions.
  final double defaultBoundaryRadiusMeters;

  /// Half-width of the uniform distance jitter applied to every peer before
  /// the UI sees it. 0 disables noise.
  final double noiseSigmaMeters;

  /// Master switch for boundary alerts (banner + OS notification).
  final bool alertsEnabled;

  /// OS-level notifications in addition to the in-app banner.
  final bool osNotificationsEnabled;

  final bool hapticsEnabled;

  /// Skip BLE entirely and always use the simulated peer stream.
  final bool forceSimulation;

  /// Name shown to others in a session. Empty until the person sets one.
  final String displayName;

  /// Use Bluetooth LE (offline, gives distance).
  final bool bluetoothEnabled;

  /// Use Wi-Fi / hotspot (Bonjour + TCP, longer range, no distance).
  final bool wifiEnabled;

  AppSettings copyWith({
    double? defaultBoundaryRadiusMeters,
    double? noiseSigmaMeters,
    bool? alertsEnabled,
    bool? osNotificationsEnabled,
    bool? hapticsEnabled,
    bool? forceSimulation,
    String? displayName,
    bool? bluetoothEnabled,
    bool? wifiEnabled,
  }) {
    return AppSettings(
      defaultBoundaryRadiusMeters:
          defaultBoundaryRadiusMeters ?? this.defaultBoundaryRadiusMeters,
      noiseSigmaMeters: noiseSigmaMeters ?? this.noiseSigmaMeters,
      alertsEnabled: alertsEnabled ?? this.alertsEnabled,
      osNotificationsEnabled:
          osNotificationsEnabled ?? this.osNotificationsEnabled,
      hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
      forceSimulation: forceSimulation ?? this.forceSimulation,
      displayName: displayName ?? this.displayName,
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      wifiEnabled: wifiEnabled ?? this.wifiEnabled,
    );
  }

  /// Returns a copy with every numeric field clamped to its valid range.
  AppSettings sanitized() {
    return copyWith(
      defaultBoundaryRadiusMeters: defaultBoundaryRadiusMeters
          .clamp(minRadius, maxRadius)
          .toDouble(),
      noiseSigmaMeters: noiseSigmaMeters.clamp(minNoise, maxNoise).toDouble(),
      displayName: displayName.length > 24
          ? displayName.substring(0, 24)
          : displayName,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'defaultBoundaryRadiusMeters': defaultBoundaryRadiusMeters,
    'noiseSigmaMeters': noiseSigmaMeters,
    'alertsEnabled': alertsEnabled,
    'osNotificationsEnabled': osNotificationsEnabled,
    'hapticsEnabled': hapticsEnabled,
    'forceSimulation': forceSimulation,
    'displayName': displayName,
    'bluetoothEnabled': bluetoothEnabled,
    'wifiEnabled': wifiEnabled,
  };

  /// Tolerant decoder: unknown/missing/mistyped fields fall back to defaults
  /// so an older or corrupted blob never prevents launch.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const AppSettings d = AppSettings();
    double num0(String k, double fallback) {
      final Object? v = json[k];
      return v is num ? v.toDouble() : fallback;
    }

    bool bool0(String k, bool fallback) {
      final Object? v = json[k];
      return v is bool ? v : fallback;
    }

    return AppSettings(
      defaultBoundaryRadiusMeters: num0(
        'defaultBoundaryRadiusMeters',
        d.defaultBoundaryRadiusMeters,
      ),
      noiseSigmaMeters: num0('noiseSigmaMeters', d.noiseSigmaMeters),
      alertsEnabled: bool0('alertsEnabled', d.alertsEnabled),
      osNotificationsEnabled: bool0(
        'osNotificationsEnabled',
        d.osNotificationsEnabled,
      ),
      hapticsEnabled: bool0('hapticsEnabled', d.hapticsEnabled),
      forceSimulation: bool0('forceSimulation', d.forceSimulation),
      displayName: json['displayName'] is String
          ? json['displayName'] as String
          : d.displayName,
      bluetoothEnabled: bool0('bluetoothEnabled', d.bluetoothEnabled),
      wifiEnabled: bool0('wifiEnabled', d.wifiEnabled),
    ).sanitized();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettings &&
          other.defaultBoundaryRadiusMeters == defaultBoundaryRadiusMeters &&
          other.noiseSigmaMeters == noiseSigmaMeters &&
          other.alertsEnabled == alertsEnabled &&
          other.osNotificationsEnabled == osNotificationsEnabled &&
          other.hapticsEnabled == hapticsEnabled &&
          other.forceSimulation == forceSimulation &&
          other.displayName == displayName &&
          other.bluetoothEnabled == bluetoothEnabled &&
          other.wifiEnabled == wifiEnabled;

  @override
  int get hashCode => Object.hash(
    defaultBoundaryRadiusMeters,
    noiseSigmaMeters,
    alertsEnabled,
    osNotificationsEnabled,
    hapticsEnabled,
    forceSimulation,
    displayName,
    bluetoothEnabled,
    wifiEnabled,
  );
}
