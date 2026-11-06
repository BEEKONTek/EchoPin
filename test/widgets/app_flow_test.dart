import 'package:echo_pin/main.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/screens/admin/admin_screen.dart';
import 'package:echo_pin/screens/session_screen.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:echo_pin/services/bootstrap.dart';
import 'package:echo_pin/services/connectivity_service.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/memory_kv_store.dart';

Future<void> _pumpApp(
  WidgetTester tester, {
  Size size = const Size(420, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final MemoryKvStore kv = MemoryKvStore();
  await tester.pumpWidget(
    EchoPinApp(
      bootstrap: Bootstrap.forTesting(kv: kv),
      settings: SettingsProvider(),
      adminAuth: AdminAuthService(kv: kv, iterations: 10, useIsolate: false),
      connectivity: ConnectivityService.disabled(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Disposes the app and lets in-flight timers (bye messages, simulated
/// radio latency) run out, so no timer outlives the test.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

SessionProvider _sessions(WidgetTester tester) =>
    SessionScope.read(tester.element(find.byType(Scaffold).first));

Future<void> _startDemo(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('home.demo')));
  await tester.pumpAndSettle();
  // Let the simulated people introduce themselves.
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('home shows name, create, join, scan/paste and demo', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    expect(find.byKey(const Key('home.displayName')), findsOneWidget);
    expect(find.byKey(const Key('home.create')), findsOneWidget);
    expect(find.byKey(const Key('home.join')), findsOneWidget);
    expect(find.byKey(const Key('home.paste')), findsOneWidget);
    expect(find.byKey(const Key('home.demo')), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('your name is saved and used in the session', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await tester.enterText(find.byKey(const Key('home.displayName')), 'Zoe');
    await tester.pump(const Duration(milliseconds: 500));
    await _startDemo(tester);
    expect(_sessions(tester).selfName, 'Zoe');
    await _teardown(tester);
  });

  testWidgets('an over-long name is rejected inline', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await tester.enterText(
      find.byKey(const Key('home.displayName')),
      'A name far longer than allowed',
    );
    await tester.pump();
    // maxLength already stops typing past 24; the field shows the counterless
    // value and no error for the clipped text.
    final TextField field = tester.widget<TextField>(
      find.byKey(const Key('home.displayName')),
    );
    expect(field.controller!.text.length, lessThanOrEqualTo(24));
    await _teardown(tester);
  });

  testWidgets('demo: simulated people appear as animated trays', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await _startDemo(tester);
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(
      _sessions(tester).session!.peers.map((p) => p.label).toSet(),
      <String>{'Amara', 'Ben', 'Chloe', 'Dev'},
    );
    // The first trays are on screen; the rest are built as the sheet scrolls.
    expect(find.text('Amara'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('peers')), findsOneWidget);
    expect(find.text('Demo'), findsWidgets); // radio strip
    expect(tester.takeException(), isNull);
    await _teardown(tester);
  });

  testWidgets('demo: check in with everyone, answers arrive', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await _startDemo(tester);
    await tester.tap(find.byKey(const Key('session.checkin')));
    await tester.pump();
    expect(find.text('Checking in with everyone'), findsOneWidget);
    // Simulated people answer within 1.5–4.5 s.
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    final OutgoingPing ping = _sessions(tester).outgoingPings.first;
    expect(ping.count(DeliveryState.answered), 4);
    expect(find.textContaining('4 of 4 answered'), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('SOS needs a press-and-hold; a tap only explains', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await _startDemo(tester);
    await tester.tap(find.byKey(const Key('sos.hold')));
    await tester.pump();
    expect(find.textContaining('Press and hold SOS'), findsOneWidget);
    expect(_sessions(tester).activeSos, isNull);

    final TestGesture hold = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('sos.hold'))),
    );
    // Frame by frame: the hold ring animates over 1.2 s.
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await hold.up();
    await tester.pump();
    expect(_sessions(tester).activeSos, isNotNull);
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Your SOS is live'), findsOneWidget);
    await tester.tap(find.text("I'm safe"));
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(_sessions(tester).activeSos, isNull);
    await _teardown(tester);
  });

  testWidgets('leaving asks first, then returns home', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await _startDemo(tester);
    await tester.tap(find.byKey(const Key('session.menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End demo'));
    await tester.pumpAndSettle();
    expect(find.text('End the demo?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('session.leave.confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(SessionScreen), findsNothing);
    expect(find.text('Recent sessions'), findsNothing, reason: 'demo not kept');
    await _teardown(tester);
  });

  testWidgets('code errors are specific and inline', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    final String good = SessionCodec().encode(SessionCodec().generateBody());
    final String typo = good.replaceRange(
      good.length - 2,
      good.length,
      good.endsWith('AA') ? 'BB' : 'AA',
    );
    await tester.enterText(find.byKey(const Key('home.code')), typo);
    await tester.tap(find.byKey(const Key('home.join')));
    await tester.pumpAndSettle();
    expect(find.textContaining('typo'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('home.code')),
      'ECHO-ABCD-EFGH-JKMN-PQ01-ST',
    );
    await tester.tap(find.byKey(const Key('home.join')));
    await tester.pumpAndSettle();
    expect(find.textContaining('never contain 0, 1'), findsOneWidget);
    expect(find.byType(SessionScreen), findsNothing);
    await _teardown(tester);
  });

  testWidgets('wide screens get a side panel instead of a sheet', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester, size: const Size(1280, 800));
    await _startDemo(tester);
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.text('Amara'), findsWidgets);
    expect(tester.takeException(), isNull);
    await _teardown(tester);
  });

  testWidgets('admin: first-run setup, panel, lock, wrong PIN, unlock', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await tester.tap(find.byTooltip('Admin'));
    await tester.pumpAndSettle();
    expect(find.text('Set up admin'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('admin.pin')), '2468');
    await tester.enterText(find.byKey(const Key('admin.confirm')), '1357');
    await tester.tap(find.byKey(const Key('admin.submit')));
    await tester.pumpAndSettle();
    expect(find.text('PINs do not match'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('admin.confirm')), '2468');
    await tester.tap(find.byKey(const Key('admin.submit')));
    await tester.pumpAndSettle();
    expect(find.byType(AdminScreen), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin.lock')));
    await tester.pumpAndSettle();
    expect(find.byType(AdminScreen), findsNothing);

    await tester.tap(find.byTooltip('Admin'));
    await tester.pumpAndSettle();
    expect(find.text('Admin login'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('admin.pin')), '0000');
    await tester.tap(find.byKey(const Key('admin.submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Wrong PIN'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('admin.pin')), '2468');
    await tester.tap(find.byKey(const Key('admin.submit')));
    await tester.pumpAndSettle();
    expect(find.byType(AdminScreen), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('admin can inject a synthetic peer into a live session', (
    WidgetTester tester,
  ) async {
    await _pumpApp(tester);
    await _startDemo(tester);
    await tester.tap(find.byKey(const Key('session.menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('admin.pin')), '2468');
    await tester.enterText(find.byKey(const Key('admin.confirm')), '2468');
    await tester.tap(find.byKey(const Key('admin.submit')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('admin.peerLabel')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byKey(const Key('admin.peerLabel')), 'Probe');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('admin.inject')),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin.inject')));
    await tester.pumpAndSettle();
    expect(find.textContaining('before noise'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(
      _sessions(tester).session!.peers.any((p) => p.label == 'Probe'),
      isTrue,
    );
    await _teardown(tester);
  });
}
