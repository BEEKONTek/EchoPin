import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoopHaptics extends HapticService {
  _NoopHaptics() : super(isEnabled: () => false);
}

class _MockBleBridge implements PlatformBleBridge {
  bool startCalled = false;

  @override
  Stream<BlePeerEvent> get peerEvents => const Stream.empty();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> start({required String sessionId, required String peerId, required String displayName}) async {
    startCalled = true;
    return true;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> injectPeer(PeerPresence peer) async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SessionProvider', () {
    late AlertProvider alerts;

    setUp(() {
      final NotificationService notifications = NotificationService(alertsEnabled: () => false);
      alerts = AlertProvider(notifications: notifications, haptics: _NoopHaptics());
    });

    tearDown(() => alerts.dispose());

    test('createSession stores an active session with a valid id', () async {
      final SessionProvider provider = SessionProvider(alertProvider: alerts, sessionCodec: SessionCodec(secret: 'test'));
      final Session session = await provider.createSession(name: 'Test', boundaryRadiusMeters: 50);
      expect(session.id.length, 8);
      expect(provider.session, isNotNull);
      expect(provider.session!.name, 'Test');
      expect(provider.session!.boundaryRadiusMeters, 50);
      provider.leaveSession();
      provider.dispose();
    });

    test('forceSimulation bypasses BLE completely', () async {
      final _MockBleBridge mockBridge = _MockBleBridge();
      final SessionProvider provider = SessionProvider(
        alertProvider: alerts,
        sessionCodec: SessionCodec(secret: 'test'),
        bleBridge: mockBridge,
      );

      await provider.createSession(name: 'Demo', forceSimulation: true);
      
      expect(provider.transportMode, TransportMode.simulated);
      expect(mockBridge.startCalled, isFalse, reason: 'BLE should not start in demo mode');
      
      provider.leaveSession();
      provider.dispose();
    });
  });
}
