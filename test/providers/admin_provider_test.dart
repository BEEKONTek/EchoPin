import 'package:echo_pin/models/admin_event.dart';
import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/providers/admin_provider.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/memory_kv_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsProvider settings;
  late AlertProvider alerts;
  late SessionProvider sessions;
  late AdminProvider admin;

  AdminProvider build({Duration autoLock = const Duration(minutes: 5)}) {
    return AdminProvider(
      auth: AdminAuthService(
        kv: MemoryKvStore(),
        iterations: 10,
        maxAttempts: 2,
        useIsolate: false,
      ),
      settings: settings,
      sessions: sessions,
      platform: const PlatformDiagnostics(
        platform: 'Test',
        usingSecureStorage: false,
        usingRealBle: false,
        notificationBackend: 'In-app only',
      ),
      autoLockAfter: autoLock,
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Zero noise so injected distances are observed exactly.
    settings = SettingsProvider(
      initial: const AppSettings(noiseSigmaMeters: 0),
    );
    alerts = AlertProvider(
      notifications: NotificationService(alertsEnabled: () => true),
      haptics: HapticService(isEnabled: () => false),
      throttle: Duration.zero,
    );
    sessions = SessionProvider(
      alertProvider: alerts,
      settings: () => settings.value,
    );
    admin = build();
  });

  tearDown(() {
    admin.dispose();
    sessions.dispose();
    alerts.dispose();
  });

  test('every privileged action refuses while locked', () async {
    expect(admin.isUnlocked, isFalse);
    expect(
      () => admin.updateSettings(const AppSettings()),
      throwsA(isA<AdminLockedException>()),
    );
    expect(() => admin.resetSettings(), throwsA(isA<AdminLockedException>()));
    expect(() => admin.clearHistory(), throwsA(isA<AdminLockedException>()));
    expect(() => admin.removePin(), throwsA(isA<AdminLockedException>()));
    expect(
      () => admin.injectPeer(bearingDegrees: 0, distanceMeters: 10),
      throwsA(isA<AdminLockedException>()),
    );
    expect(() => admin.removePeer('x'), throwsA(isA<AdminLockedException>()));
    expect(admin.clearLog, throwsA(isA<AdminLockedException>()));
  });

  test('createPin unlocks and cannot overwrite an existing PIN', () async {
    await admin.refresh();
    expect(admin.hasPin, isFalse);
    await admin.createPin('1234');
    expect(admin.isUnlocked, isTrue);
    expect(admin.hasPin, isTrue);
    admin.lock();
    expect(() => admin.createPin('9999'), throwsStateError);
  });

  test('unlock with wrong PIN stays locked and is audited', () async {
    await admin.createPin('1234');
    admin.lock();
    final AdminAuthResult r = await admin.unlock('0000');
    expect(r.ok, isFalse);
    expect(admin.isUnlocked, isFalse);
    expect(admin.log.first.type, AdminEventType.unlockFailed);
    expect((await admin.unlock('1234')).ok, isTrue);
    expect(admin.isUnlocked, isTrue);
  });

  test('settings changes are applied and diffed in the log', () async {
    await admin.createPin('1234');
    await admin.updateSettings(
      admin.settings.copyWith(defaultBoundaryRadiusMeters: 300),
    );
    expect(settings.value.defaultBoundaryRadiusMeters, 300);
    expect(admin.log.first.type, AdminEventType.settingsChanged);
    expect(admin.log.first.detail, contains('radius: 150 → 300'));
  });

  test('injected peer appears in session and can drive a crossing', () async {
    await admin.createPin('1234');
    await sessions.createSession(
      name: 'T',
      boundaryRadiusMeters: 100,
      forceSimulation: true,
    );
    final PeerPresence p = admin.injectPeer(
      label: 'Probe',
      bearingDegrees: 90,
      distanceMeters: 50,
    );
    await Future<void>.delayed(Duration.zero);
    final PeerPresence seen = sessions.session!.peers.firstWhere(
      (PeerPresence x) => x.id == p.id,
    );
    expect(seen.distanceMeters, 50);
    expect(sessions.isSynthetic(p.id), isTrue);

    admin.injectPeer(
      id: p.id,
      label: 'Probe',
      bearingDegrees: 90,
      distanceMeters: 200,
    );
    await Future<void>.delayed(Duration.zero);
    expect(alerts.current?.peerId, p.id);
    expect(alerts.current?.direction, CrossingDirection.exited);

    admin.removePeer(p.id);
    await Future<void>.delayed(Duration.zero);
    expect(
      sessions.session!.peers.any((PeerPresence x) => x.id == p.id),
      isFalse,
    );
    await sessions.leaveSession();
  });

  test('injecting without a session is an error', () async {
    await admin.createPin('1234');
    expect(
      () => admin.injectPeer(bearingDegrees: 0, distanceMeters: 1),
      throwsStateError,
    );
  });

  test('auto-locks after inactivity', () async {
    admin.dispose();
    admin = build(autoLock: const Duration(milliseconds: 30));
    await admin.createPin('1234');
    expect(admin.isUnlocked, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(admin.isUnlocked, isFalse);
    expect(admin.log.first.type, AdminEventType.locked);
  });

  test('removePin locks and returns to first-run setup', () async {
    await admin.createPin('1234');
    await admin.removePin();
    expect(admin.isUnlocked, isFalse);
    expect(admin.hasPin, isFalse);
    await admin.createPin('5678');
    expect(admin.isUnlocked, isTrue);
  });

  test('diagnostics report session state', () async {
    await admin.createPin('1234');
    expect(admin.diagnostics()['Session'], 'None');
    await sessions.createSession(name: 'Diag', forceSimulation: true);
    final Map<String, String> d = admin.diagnostics();
    expect(d['Presence source'], 'Simulated');
    expect(d['Session'], startsWith('Diag (demo) · id '));
    expect(d['Radios'], contains('Simulation: running'));
    expect(d['Your safety code'], matches(RegExp(r'^\d{4} \d{4} \d{4}$')));
    expect(d['Messages'], startsWith('sent '));
    // Never leak the secret invite code into diagnostics.
    expect(d.values.join(' '), isNot(contains(sessions.sessionCode!)));
    await sessions.leaveSession();
  });
}
