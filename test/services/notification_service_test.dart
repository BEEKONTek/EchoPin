import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/services/notification_backend.dart';
import 'package:echo_pin/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingBackend implements NotificationBackend {
  final List<BoundaryAlert> shown = <BoundaryAlert>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> showBoundaryAlert(BoundaryAlert alert) async {
    shown.add(alert);
  }
}

BoundaryAlert _alert(String id) {
  return BoundaryAlert(
    id: id,
    peerId: 'peer-$id',
    peerLabel: 'Peer $id',
    direction: CrossingDirection.entered,
    distanceMeters: 10,
    at: DateTime.utc(2024),
  );
}

void main() {
  group('NotificationService', () {
    test('push forwards to backend and to active queue', () async {
      final _RecordingBackend backend = _RecordingBackend();
      final NotificationService svc = NotificationService(
        alertsEnabled: () => true,
        backend: backend,
      );

      svc.push(_alert('a'));
      await Future<void>.microtask(() {});

      expect(svc.active.length, 1);
      expect(svc.current?.id, 'a');
      expect(backend.shown.length, 1);
    });

    test('push is a no-op when alerts are disabled', () async {
      final _RecordingBackend backend = _RecordingBackend();
      final NotificationService svc = NotificationService(
        alertsEnabled: () => false,
        backend: backend,
      );

      svc.push(_alert('a'));
      await Future<void>.microtask(() {});

      expect(svc.active, isEmpty);
      expect(backend.shown, isEmpty);
    });

    test('queue caps at 3, newest first', () {
      final NotificationService svc = NotificationService(
        alertsEnabled: () => true,
        backend: _RecordingBackend(),
      );
      svc
        ..push(_alert('a'))
        ..push(_alert('b'))
        ..push(_alert('c'))
        ..push(_alert('d'));

      expect(svc.active.length, 3);
      expect(svc.active.map((BoundaryAlert a) => a.id), <String>['d', 'c', 'b']);
    });

    test('dismiss removes a single alert', () {
      final NotificationService svc = NotificationService(
        alertsEnabled: () => true,
        backend: _RecordingBackend(),
      );
      svc
        ..push(_alert('a'))
        ..push(_alert('b'));
      svc.dismiss('a');
      expect(svc.active.length, 1);
      expect(svc.current?.id, 'b');
    });

    test('dismissAll clears the queue', () {
      final NotificationService svc = NotificationService(
        alertsEnabled: () => true,
        backend: _RecordingBackend(),
      );
      svc
        ..push(_alert('a'))
        ..push(_alert('b'));
      svc.dismissAll();
      expect(svc.active, isEmpty);
      expect(svc.current, isNull);
    });

    test('notifies listeners on push and dismiss', () {
      final NotificationService svc = NotificationService(
        alertsEnabled: () => true,
        backend: _RecordingBackend(),
      );
      int notifications = 0;
      svc.addListener(() => notifications++);

      svc.push(_alert('a'));
      svc.dismiss('a');
      svc.push(_alert('b'));
      svc.dismissAll();

      expect(notifications, 4);
    });

    test('push with same id replaces rather than duplicates', () {
      final NotificationService svc = NotificationService(
        alertsEnabled: () => true,
        backend: _RecordingBackend(),
      );
      svc
        ..push(_alert('a'))
        ..push(_alert('a'));
      expect(svc.active.length, 1);
    });
  });
}
