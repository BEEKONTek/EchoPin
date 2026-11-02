import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/providers/alert_provider.dart';
import 'package:echo_pin/services/haptic_service.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingHaptics extends HapticService {
  _CountingHaptics() : super(isEnabled: () => true);

  int lightCount = 0;
  int mediumCount = 0;

  @override
  Future<void> light() async {
    lightCount++;
  }

  @override
  Future<void> medium() async {
    mediumCount++;
  }
}

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
}
