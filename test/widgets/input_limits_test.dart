// Every free-text field the server length-checks is capped in the UI at
// the same number, and obvious mistakes are caught before any network.
import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/main.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:echo_pin/services/bootstrap.dart';
import 'package:echo_pin/services/connectivity_service.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_echopin_server.dart';
import '../helpers/memory_kv_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  late FakeEchoPinServer server;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server = (await tester.runAsync(FakeEchoPinServer.start))!;
    final MemoryKvStore kv = MemoryKvStore();
    final AccountProvider account = AccountProvider(
      kv: kv,
      platform: 'Android',
      appVersion: '0.5.0',
      api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
    );
    addTearDown(account.dispose);
    await tester.pumpWidget(
      EchoPinApp(
        bootstrap: Bootstrap.forTesting(kv: kv),
        settings: SettingsProvider(),
        adminAuth: AdminAuthService(kv: kv, iterations: 10, useIsolate: false),
        accountLockAuth: AdminAuthService.account(
          kv: kv,
          iterations: 10,
          useIsolate: false,
        ),
        connectivity: ConnectivityService.disabled(),
        account: account,
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  int? maxLengthOf(WidgetTester tester, Key key) =>
      tester.widget<TextField>(find.byKey(key)).maxLength;

  testWidgets('sign-in fields are capped at the server limits', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('home.account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('signin.toRegister')));
    await tester.pumpAndSettle();
    expect(
      maxLengthOf(tester, const Key('signin.name')),
      ProtocolLimits.maxDisplayName,
    );
    expect(
      maxLengthOf(tester, const Key('signin.email')),
      ProtocolLimits.maxEmail,
    );
    expect(
      maxLengthOf(tester, const Key('signin.password')),
      ProtocolLimits.maxPasswordLength,
    );
    // The limits are enforced, not just displayed.
    await tester.enterText(find.byKey(const Key('signin.name')), 'x' * 100);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('signin.name')))
          .controller!
          .text
          .length,
      ProtocolLimits.maxDisplayName,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home fields are capped too', (WidgetTester tester) async {
    await pumpApp(tester);
    expect(maxLengthOf(tester, const Key('home.displayName')), 24);
    expect(maxLengthOf(tester, const Key('home.name')), 40);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'an obviously wrong email or empty password is refused before any request',
    (WidgetTester tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('home.account')));
      await tester.pumpAndSettle();
      final int before = server.requests;
      await tester.enterText(
        find.byKey(const Key('signin.email')),
        'not-an-email',
      );
      await tester.enterText(
        find.byKey(const Key('signin.password')),
        'correct horse battery',
      );
      await tester.tap(find.byKey(const Key('signin.submit')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid email address'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('signin.email')),
        'ana@example.com',
      );
      await tester.enterText(find.byKey(const Key('signin.password')), '');
      await tester.tap(find.byKey(const Key('signin.submit')));
      await tester.pumpAndSettle();
      expect(find.text('Enter your password'), findsOneWidget);
      expect(server.requests, before, reason: 'nothing was sent to the server');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
