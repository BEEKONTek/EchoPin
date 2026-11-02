import 'package:echo_pin/models/session_summary.dart';
import 'package:echo_pin/services/session_history_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

SessionSummary _summary(String id, {String? code}) {
  return SessionSummary(
    id: id,
    name: 'Session $id',
    code: code ?? 'ECHO-AAAA-BBBB-CC',
    boundaryRadiusMeters: 150,
    createdAt: DateTime.utc(2024),
    lastJoinedAt: DateTime.utc(2024, 6, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('SessionHistoryService', () {
    test('load returns empty list when nothing persisted', () async {
      final SessionHistoryService svc = SessionHistoryService();
      expect(await svc.load(), isEmpty);
    });

    test('record then load returns newest first', () async {
      final SessionHistoryService svc = SessionHistoryService();
      await svc.record(_summary('a'));
      await svc.record(_summary('b'));
      final List<SessionSummary> list = await svc.load();
      expect(list.length, 2);
      expect(list.first.id, 'b');
      expect(list.last.id, 'a');
    });

    test(
      're-recording the same id moves it to the top without duplicating',
      () async {
        final SessionHistoryService svc = SessionHistoryService();
        await svc.record(_summary('a'));
        await svc.record(_summary('b'));
        await svc.record(_summary('a'));
        final List<SessionSummary> list = await svc.load();
        expect(list.length, 2);
        expect(list.first.id, 'a');
      },
    );

    test('caps storage at 20 entries', () async {
      final SessionHistoryService svc = SessionHistoryService();
      for (int i = 0; i < 25; i++) {
        await svc.record(_summary('id$i'));
      }
      final List<SessionSummary> list = await svc.load();
      expect(list.length, 20);
      expect(list.first.id, 'id24');
    });

    test('clear wipes all history', () async {
      final SessionHistoryService svc = SessionHistoryService();
      await svc.record(_summary('a'));
      await svc.clear();
      expect(await svc.load(), isEmpty);
    });

    test('corrupted JSON returns an empty list rather than throwing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'echo_pin.session_history': 'not-json',
      });
      final SessionHistoryService svc = SessionHistoryService();
      expect(await svc.load(), isEmpty);
    });

    test('summary JSON round-trips all fields', () {
      final SessionSummary original = _summary('round-trip');
      final SessionSummary restored = SessionSummary.fromJson(
        original.toJson(),
      );
      expect(restored, original);
    });
  });
}
