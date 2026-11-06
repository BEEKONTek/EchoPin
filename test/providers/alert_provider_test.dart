import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingHaptics extends HapticService {
  _CountingHaptics() : super(isEnabled: () => true);

  int lightCount = 0;
  int mediumCount = 0;
  int sosCount = 0;

  @override
  Future<void> sos() async {
    sosCount++;
  }

  @override
  Future<void> light() async {
    lightCount++;
  }

  @override
  Future<void> medium() async {
    mediumCount++;
  }
}

class _Notices implements NotificationBackend {
  final List<LocalNotice> shown = <LocalNotice>[];
  @override
  String get name => 'test';
  @override
  Future<void> initialize() async {}
  @override
  Future<void> requestPermissions() async {}
  @override
  Future<void> showBoundaryAlert(BoundaryAlert alert) async {}
  @override
  Future<void> showNotice(LocalNotice notice) async => shown.add(notice);
}

IncomingPing _ping(PingKind kind) => IncomingPing(
  id: 'PINGAAAA',
  kind: kind,
  fromId: 'PEERAAAA',
  fromName: 'Amara',
  receivedAt: DateTime(2026),
);

BoundaryAlert _alert({
  required String id,
  required String peerId,
  CrossingDirection direction = CrossingDirection.entered,
}) {
  return BoundaryAlert(
    id: id,
    peerId: peerId,
    peerLabel: 'Peer $peerId',
    direction: direction,
    distanceMeters: 10,
    at: DateTime.utc(2024),
  );
}

void main() {
  group('AlertProvider', () {
    late NotificationService notifications;
    late _CountingHaptics haptics;
    late AlertProvider provider;

    setUp(() {
      notifications = NotificationService(alertsEnabled: () => true);
      haptics = _CountingHaptics();
      provider = AlertProvider(
        notifications: notifications,
        haptics: haptics,
        throttle: const Duration(milliseconds: 50),
      );
    });

    tearDown(() {
      provider.dispose();
    });

    test('handleCrossing pushes to queue and fires haptic', () async {
      provider.handleCrossing(_alert(id: 'a', peerId: 'p1'));
      await Future<void>.microtask(() {});

      expect(notifications.active.length, 1);
      expect(haptics.lightCount, 1);
      expect(haptics.mediumCount, 0);
    });

    test('exiting peer triggers medium haptic', () async {
      provider.handleCrossing(
        _alert(id: 'a', peerId: 'p1', direction: CrossingDirection.exited),
      );
      await Future<void>.microtask(() {});

      expect(haptics.mediumCount, 1);
      expect(haptics.lightCount, 0);
    });

    test('throttles repeated crossings for the same peer', () async {
      provider.handleCrossing(_alert(id: 'a', peerId: 'p1'));
      provider.handleCrossing(_alert(id: 'b', peerId: 'p1'));
      provider.handleCrossing(_alert(id: 'c', peerId: 'p1'));
      await Future<void>.microtask(() {});

      expect(notifications.active.length, 1);
      expect(haptics.lightCount, 1);
    });

    test('throttle window expires and allows a new crossing', () async {
      provider.handleCrossing(_alert(id: 'a', peerId: 'p1'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      provider.handleCrossing(_alert(id: 'b', peerId: 'p1'));
      await Future<void>.microtask(() {});

      expect(haptics.lightCount, 2);
    });

    test('different peers do not throttle each other', () async {
      provider.handleCrossing(_alert(id: 'a', peerId: 'p1'));
      provider.handleCrossing(_alert(id: 'b', peerId: 'p2'));
      await Future<void>.microtask(() {});

      expect(notifications.active.length, 2);
      expect(haptics.lightCount, 2);
    });

    test('notifies listeners when queue changes', () async {
      int notificationsCount = 0;
      provider.addListener(() => notificationsCount++);

      provider.handleCrossing(_alert(id: 'a', peerId: 'p1'));
      provider.dismiss('a');

      expect(notificationsCount, greaterThanOrEqualTo(2));
    });
  });

  group('AlertProvider pings', () {
    test('OS switch off: check-ins stay in-app, SOS still notifies', () {
      final _Notices backend = _Notices();
      final _CountingHaptics haptics = _CountingHaptics();
      final AlertProvider p = AlertProvider(
        notifications: NotificationService(
          alertsEnabled: () => false,
          osNotificationsEnabled: () => false,
          backend: backend,
        ),
        haptics: haptics,
      );
      p.handlePing(_ping(PingKind.checkIn));
      expect(backend.shown, isEmpty);
      expect(haptics.mediumCount, 1);

      p.handlePing(_ping(PingKind.sos));
      expect(backend.shown.single.urgency, NoticeUrgency.critical);
      expect(backend.shown.single.title, 'SOS from Amara');
      expect(haptics.sosCount, 1);
      p.dispose();
    });

    test('OS switch on: check-ins notify at high urgency', () {
      final _Notices backend = _Notices();
      final AlertProvider p = AlertProvider(
        notifications: NotificationService(
          alertsEnabled: () => true,
          backend: backend,
        ),
        haptics: _CountingHaptics(),
      );
      p.handlePing(_ping(PingKind.checkIn));
      expect(backend.shown.single.urgency, NoticeUrgency.high);
      p.dispose();
    });
  });
}
