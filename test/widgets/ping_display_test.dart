import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:echo_pin/widgets/peer_tray.dart';
import 'package:echo_pin/widgets/ping_trays.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: EchoTheme.dark(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

final DateTime _now = DateTime(2026, 11, 6, 12);

IncomingPing _sos({PingResponse? response}) => IncomingPing(
  id: 'p1',
  kind: PingKind.sos,
  fromId: 'peer-a',
  fromName: 'Ana',
  receivedAt: _now,
  response: response,
);

const PeerPresence _ana = PeerPresence(
  id: 'peer-a',
  label: 'Ana',
  bearingDegrees: 0,
  distanceMeters: 0,
  hasDistance: false,
);

void main() {
  group('someone else\'s SOS', () {
    testWidgets('offers "On my way" until answered', (WidgetTester t) async {
      await _pump(
        t,
        IncomingPingTray(ping: _sos(), onRespond: (_) {}, onDismiss: () {}),
      );
      expect(find.byKey(const Key('ping.answer.coming')), findsOneWidget);
    });

    testWidgets('after "On my way" says so instead of asking again', (
      WidgetTester t,
    ) async {
      await _pump(
        t,
        IncomingPingTray(
          ping: _sos(response: PingResponse.coming),
          onRespond: (_) {},
          onDismiss: () {},
        ),
      );
      expect(find.text('Ana needs help'), findsOneWidget);
      expect(find.byKey(const Key('ping.answer.coming')), findsNothing);
      expect(find.text("You're on your way"), findsOneWidget);
    });
  });

  group('peer row', () {
    // Ana said "I'm OK" to an earlier check-in, then sent an SOS.
    final RecipientStatus okEarlier = const RecipientStatus(
      peerId: 'peer-a',
      name: 'Ana',
      state: DeliveryState.answered,
      response: PingResponse.ok,
    );

    testWidgets('shows the last answer when nobody needs help', (
      WidgetTester t,
    ) async {
      await _pump(
        t,
        PeerTray(
          peer: _ana,
          boundaryRadius: 150,
          now: _now,
          pingState: okEarlier,
        ),
      );
      expect(find.text('OK'), findsOneWidget);
    });

    testWidgets('a live SOS from them outranks an earlier "OK"', (
      WidgetTester t,
    ) async {
      await _pump(
        t,
        PeerTray(
          peer: _ana,
          boundaryRadius: 150,
          now: _now,
          pingState: okEarlier,
          needsHelp: true,
        ),
      );
      expect(find.text('OK'), findsNothing);
      expect(find.text('SOS'), findsOneWidget);
    });
  });
}
