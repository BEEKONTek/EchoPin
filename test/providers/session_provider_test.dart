import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoopHaptics extends HapticService {
  _NoopHaptics() : super(isEnabled: () => false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SessionProvider', () {
    late AlertProvider alerts;
    late SessionProvider provider;

    setUp(() {
      final NotificationService notifications = NotificationService(
        alertsEnabled: () => true,
      );
      alerts = AlertProvider(
        notifications: notifications,
        haptics: _NoopHaptics(),
      );
      provider = SessionProvider(
        alertProvider: alerts,
        sessionCodec: SessionCodec(secret: 'test-secret'),
      );
    });

    tearDown(() {
      provider.dispose();
      alerts.dispose();
    });

    test('createSession stores an active session with a valid id', () async {
      final Session session = await provider.createSession(
        name: 'Test',
        boundaryRadiusMeters: 50,
      );
      expect(session.id.length, 8);
      expect(provider.session, isNotNull);
      expect(provider.session!.name, 'Test');
      expect(provider.session!.boundaryRadiusMeters, 50);
      provider.leaveSession();
    });

    test('joinSession accepts an explicit id', () async {
      final Session session = await provider.joinSession(
        sessionName: 'Joined',
        sessionId: 'JOINDEMO',
      );
      expect(session.id, 'JOINDEMO');
      provider.leaveSession();
    });

    test('peer update that crosses the boundary fires an alert', () async {
      await provider.createSession(name: 'Test', boundaryRadiusMeters: 50);
      final List<PeerPresence> updated = <PeerPresence>[
        const PeerPresence(
          id: 'peer-a',
          label: 'Peer A',
          bearingDegrees: 0,
          distanceMeters: 10,
        ),
        const PeerPresence(
          id: 'peer-b',
          label: 'Peer B',
          bearingDegrees: 120,
          distanceMeters: 142,
        ),
        const PeerPresence(
          id: 'peer-c',
          label: 'Peer C',
          bearingDegrees: 200,
          distanceMeters: 254,
        ),
        const PeerPresence(
          id: 'peer-d',
          label: 'Peer D',
          bearingDegrees: 320,
          distanceMeters: 90,
        ),
      ];
      provider.meshService.simulatePeerUpdate(updated);
      await Future<void>.microtask(() {});

      expect(alerts.active.length, 1);
      expect(alerts.current?.peerId, 'peer-a');
      expect(alerts.current?.direction, CrossingDirection.entered);

      // Session state also reflects the new peer list.
      expect(provider.session!.peers.first.distanceMeters, 10);
      provider.leaveSession();
    });

    test('peer update that does not cross boundary fires nothing', () async {
      await provider.createSession(name: 'Test', boundaryRadiusMeters: 500);
      final List<PeerPresence> updated = <PeerPresence>[
        const PeerPresence(
          id: 'peer-a',
          label: 'Peer A',
          bearingDegrees: 0,
          distanceMeters: 100,
        ),
      ];
      provider.meshService.simulatePeerUpdate(updated);
      await Future<void>.microtask(() {});

      expect(alerts.active, isEmpty);
      provider.leaveSession();
    });

    test(
      'updateBoundaryRadius updates session radius without alerts',
      () async {
        await provider.createSession(name: 'Test', boundaryRadiusMeters: 150);
        provider.updateBoundaryRadius(200);
        await Future<void>.microtask(() {});

        expect(provider.session!.boundaryRadiusMeters, 200);
        expect(alerts.active, isEmpty);
        provider.leaveSession();
      },
    );

    test('leaveSession clears session and alerts', () async {
      await provider.createSession(name: 'Test', boundaryRadiusMeters: 50);
      provider.meshService.simulatePeerUpdate(<PeerPresence>[
        const PeerPresence(
          id: 'peer-a',
          label: 'Peer A',
          bearingDegrees: 0,
          distanceMeters: 10,
        ),
      ]);
      await Future<void>.microtask(() {});
      expect(alerts.active, isNotEmpty);

      provider.leaveSession();
      expect(provider.session, isNull);
      expect(alerts.active, isEmpty);
    });

    test('history records created sessions', () async {
      await provider.createSession(name: 'Test', boundaryRadiusMeters: 150);
      expect(provider.history.length, 1);
      expect(provider.history.first.name, 'Test');
      provider.leaveSession();
    });
  });
}
