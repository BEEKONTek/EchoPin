import 'package:echo_pin/models/ping.dart';
import 'package:flutter_test/flutter_test.dart';

IncomingPing _ping(
  PingKind kind, {
  PingResponse? response,
  bool dismissed = false,
  bool resolved = false,
}) {
  return IncomingPing(
    id: 'p1',
    kind: kind,
    fromId: 'peer-a',
    fromName: 'Ana',
    receivedAt: DateTime(2026, 11, 6, 12),
    response: response,
    dismissed: dismissed,
    resolved: resolved,
  );
}

void main() {
  group('IncomingPing.open', () {
    final List<(String, IncomingPing, bool)>
    cases = <(String, IncomingPing, bool)>[
      ('unanswered check-in', _ping(PingKind.checkIn), true),
      (
        'answered check-in',
        _ping(PingKind.checkIn, response: PingResponse.ok),
        false,
      ),
      ('dismissed check-in', _ping(PingKind.checkIn, dismissed: true), false),
      ('unanswered SOS', _ping(PingKind.sos), true),
      // A responder still needs the alert: the sender is not safe yet.
      (
        'SOS answered "On my way"',
        _ping(PingKind.sos, response: PingResponse.coming),
        true,
      ),
      (
        'SOS whose sender is safe',
        _ping(PingKind.sos, response: PingResponse.coming, resolved: true),
        false,
      ),
      ('dismissed SOS', _ping(PingKind.sos, dismissed: true), false),
    ];
    for (final (String name, IncomingPing ping, bool open) in cases) {
      test(name, () => expect(ping.open, open));
    }
  });
}
