import 'dart:async';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/services/ble_permission_service.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/mesh_service.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBridge implements PlatformBleBridge {
  final StreamController<BlePeerEvent> _events =
      StreamController<BlePeerEvent>.broadcast();
  bool startResult = true;

  @override
  Stream<BlePeerEvent> get peerEvents => _events.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
    required String displayName,
  }) async =>
      startResult;

  @override
  Future<void> stop() async {}

  @override
  Future<void> injectPeer(PeerPresence peer) async {}

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }
}

class _NoopHaptics extends HapticService {
  _NoopHaptics() : super(isEnabled: () => false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SessionProvider BLE selection', () {
    late AlertProvider alerts;

    setUp(() {
      final NotificationService notifications =
          NotificationService(alertsEnabled: () => false);
      alerts = AlertProvider(
        notifications: notifications,
        haptics: _NoopHaptics(),
      );
    });

    tearDown(() => alerts.dispose());

    test('no bridge → simulated transport', () async {
      final SessionProvider p = SessionProvider(
        alertProvider: alerts,
        sessionCodec: SessionCodec(secret: 'test'),
      );
      await p.createSession(name: 'T');
      expect(p.transportMode, TransportMode.simulated);
      p.leaveSession();
      p.dispose();
    });

    test('bridge + permission granted → BLE transport', () async {
      final _FakeBridge bridge = _FakeBridge();
      final SessionProvider p = SessionProvider(
        alertProvider: alerts,
        sessionCodec: SessionCodec(secret: 'test'),
        bleBridge: bridge,
        permissionService:
            BlePermissionService(request: () async => true),
      );
      await p.createSession(name: 'T');
      expect(p.transportMode, TransportMode.ble);
      expect(p.session!.peers, isEmpty);
      p.leaveSession();
      p.dispose();
      await bridge.dispose();
    });

    test('permission denied → simulated fallback', () async {
      final _FakeBridge bridge = _FakeBridge();
      final SessionProvider p = SessionProvider(
        alertProvider: alerts,
        sessionCodec: SessionCodec(secret: 'test'),
        bleBridge: bridge,
        permissionService:
            BlePermissionService(request: () async => false),
      );
      await p.createSession(name: 'T');
      expect(p.transportMode, TransportMode.simulated);
      p.leaveSession();
      p.dispose();
      await bridge.dispose();
    });

    test('bridge refuses start → simulated fallback', () async {
      final _FakeBridge bridge = _FakeBridge()..startResult = false;
      final SessionProvider p = SessionProvider(
        alertProvider: alerts,
        sessionCodec: SessionCodec(secret: 'test'),
        bleBridge: bridge,
        permissionService:
            BlePermissionService(request: () async => true),
      );
      await p.createSession(name: 'T');
      expect(p.transportMode, TransportMode.simulated);
      p.leaveSession();
      p.dispose();
      await bridge.dispose();
    });
  });
}
