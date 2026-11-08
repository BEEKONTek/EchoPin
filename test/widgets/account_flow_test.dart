import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/main.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/screens/account/account_screen.dart';
import 'package:echo_pin/screens/account/sign_in_screen.dart';
import 'package:echo_pin/screens/console/console_screen.dart';
import 'package:echo_pin/screens/report_screen.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:echo_pin/services/bootstrap.dart';
import 'package:echo_pin/services/connectivity_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_echopin_server.dart';
import '../helpers/memory_kv_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  late FakeEchoPinServer server;

  Future<AccountProvider> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server = (await tester.runAsync(FakeEchoPinServer.start))!;
    final MemoryKvStore kv = MemoryKvStore();
    final AccountProvider account = AccountProvider(
      kv: kv,
      platform: 'Android',
      appVersion: '0.4.0',
      api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
    );
    addTearDown(account.dispose);
    await tester.pumpWidget(
      EchoPinApp(
        bootstrap: Bootstrap.forTesting(kv: kv),
        settings: SettingsProvider(),
        adminAuth: AdminAuthService(kv: kv, iterations: 10, useIsolate: false),
        connectivity: ConnectivityService.disabled(),
        account: account,
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    return account;
  }

  Future<void> settle(WidgetTester tester) async {
    // Crypto and the fake server complete on the real event loop.
    for (int i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (int i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('live sessions ask for sign-in first; the demo does not', (WidgetTester tester) async {
    final AccountProvider account = await pumpApp(tester);
    expect(find.textContaining('Sign in to start or join live sessions'), findsOneWidget);
    expect(find.byKey(const Key('home.account')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home.create')));
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);

    await tester.enterText(find.byKey(const Key('signin.email')), 'ana@example.com');
    await tester.enterText(find.byKey(const Key('signin.password')), 'wrong password!!');
    await tester.tap(find.byKey(const Key('signin.submit')));
    await settle(tester);
    expect(find.text('That email and password do not match'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('signin.password')), 'correct horse battery');
    await tester.tap(find.byKey(const Key('signin.submit')));
    await settle(tester);
    expect(account.signedIn, isTrue);
    expect(find.byType(SignInScreen), findsNothing);
    expect(find.textContaining('Sign in to start or join live sessions'), findsNothing);
    await teardown(tester);
  });

  testWidgets('two-step sign-in reveals the code field', (WidgetTester tester) async {
    await pumpApp(tester);
    server.totpRequired = true;
    await tester.tap(find.byKey(const Key('home.account')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('signin.email')), 'ana@example.com');
    await tester.enterText(find.byKey(const Key('signin.password')), 'correct horse battery');
    await tester.tap(find.byKey(const Key('signin.submit')));
    await settle(tester);
    expect(find.byKey(const Key('signin.totp')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('signin.totp')), '123456');
    await tester.tap(find.byKey(const Key('signin.submit')));
    await settle(tester);
    expect(find.byType(AccountScreen), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a responder reaches the console overview; a member does not see it', (WidgetTester tester) async {
    final AccountProvider account = await pumpApp(tester);
    server.role = 'responder';
    await tester.runAsync(() => account.signIn(email: 'ana@example.com', password: 'correct horse battery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);
    expect(find.byType(AccountScreen), findsOneWidget);
    await tester.tap(find.byKey(const Key('account.console')));
    await settle(tester);
    expect(find.byType(ConsoleScreen), findsOneWidget);
    expect(find.text('Open reports'), findsOneWidget);
    expect(find.textContaining('1 critical report open'), findsOneWidget);
    expect(find.text('Sessions per day'), findsOneWidget);
    // Responders get reports and sessions, not people or backups.
    Finder nav(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));
    expect(nav('Sessions'), findsOneWidget);
    expect(nav('People'), findsNothing);
    expect(nav('Backups'), findsNothing);
    await teardown(tester);
  });

  testWidgets('a safety report marked urgent goes up as critical', (WidgetTester tester) async {
    final AccountProvider account = await pumpApp(tester);
    await tester.runAsync(() => account.signIn(email: 'ana@example.com', password: 'correct horse battery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);
    expect(find.byKey(const Key('account.console')), findsNothing, reason: 'members have no console');
    await tester.tap(find.byKey(const Key('account.report')));
    await tester.pumpAndSettle();
    expect(find.byType(ReportScreen), findsOneWidget);

    await tester.tap(find.byKey(const Key('report.category.safety')));
    await tester.pumpAndSettle();
    expect(find.textContaining('hold SOS'), findsOneWidget);
    await tester.tap(find.byKey(const Key('report.urgent')));
    await tester.enterText(find.byKey(const Key('report.subject')), 'Lost contact with Ben');
    await tester.enterText(find.byKey(const Key('report.body')), 'Last seen near the north ridge at 14:00');
    await tester.scrollUntilVisible(find.byKey(const Key('report.send')), 200,
        scrollable: find.descendant(of: find.byType(ReportScreen), matching: find.byType(Scrollable)).first);
    await tester.tap(find.byKey(const Key('report.send')));
    await settle(tester);
    expect(server.reports.single['severity'], 'critical');
    expect(server.reports.single['category'], 'safety');
    expect(server.reports.single['diagnostics'], isA<Map<String, dynamic>>());
    expect(find.byType(ReportScreen), findsNothing);
    await teardown(tester);
  });
}
