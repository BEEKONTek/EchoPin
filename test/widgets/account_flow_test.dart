import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/main.dart';
import 'package:echo_pin/providers/account_lock_scope.dart';
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
        accountLockAuth: AdminAuthService.account(kv: kv, iterations: 10, useIsolate: false),
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

  /// Right after signing in, Account asks for a new PIN first.
  Future<void> createPin(WidgetTester tester, [String pin = '2468']) async {
    expect(find.text('Protect your account'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('accountLock.pin')), pin);
    await tester.enterText(find.byKey(const Key('accountLock.confirm')), pin);
    await tester.tap(find.byKey(const Key('accountLock.submit')));
    await settle(tester);
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
    await createPin(tester);
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
    await createPin(tester);
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
    await createPin(tester);
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

  testWidgets('the account PIN: lock, wrong PIN, unlock, and the demo never asks', (WidgetTester tester) async {
    final AccountProvider account = await pumpApp(tester);
    await tester.runAsync(() => account.signIn(email: 'ana@example.com', password: 'correct horse battery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);
    await createPin(tester);
    expect(find.byType(AccountScreen), findsOneWidget);

    // Lock: back to home. Opening Account again asks for the PIN.
    await tester.tap(find.byKey(const Key('account.lock')));
    await settle(tester);
    expect(find.byType(AccountScreen), findsNothing);
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);
    expect(find.text('Account locked'), findsOneWidget);
    expect(find.byType(AccountScreen), findsNothing, reason: 'nothing loads before the PIN');

    await tester.enterText(find.byKey(const Key('accountLock.pin')), '0000');
    await tester.tap(find.byKey(const Key('accountLock.submit')));
    await settle(tester);
    expect(find.text('Wrong PIN. 4 attempt(s) left.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('accountLock.pin')), '2468');
    await tester.tap(find.byKey(const Key('accountLock.submit')));
    await settle(tester);
    expect(find.byType(AccountScreen), findsOneWidget);

    // Sessions don't need the PIN, even while locked.
    await tester.tap(find.byKey(const Key('account.lock')));
    await settle(tester);
    await tester.tap(find.text('Try the demo (simulated people)'));
    await settle(tester);
    expect(find.text('Account locked'), findsNothing);
    await teardown(tester);
  });

  testWidgets('forgot PIN signs out and returns home', (WidgetTester tester) async {
    final AccountProvider account = await pumpApp(tester);
    await tester.runAsync(() => account.signIn(email: 'ana@example.com', password: 'correct horse battery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);
    await createPin(tester);
    await tester.tap(find.byKey(const Key('account.lock')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);

    await tester.tap(find.byKey(const Key('accountLock.forgot')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accountLock.forgotConfirm')));
    await settle(tester);
    expect(account.signedIn, isFalse);
    expect(find.text('Account locked'), findsNothing);
    expect(find.textContaining('Sign in to start or join live sessions'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('change the account PIN from Account', (WidgetTester tester) async {
    final AccountProvider account = await pumpApp(tester);
    await tester.runAsync(() => account.signIn(email: 'ana@example.com', password: 'correct horse battery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);
    await createPin(tester);
    await tester.scrollUntilVisible(find.byKey(const Key('account.changePin')), 200,
        scrollable: find.descendant(of: find.byType(AccountScreen), matching: find.byType(Scrollable)).first);
    await tester.tap(find.byKey(const Key('account.changePin')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('changePin.current')), '2468');
    await tester.enterText(find.byKey(const Key('changePin.new')), '1357');
    await tester.enterText(find.byKey(const Key('changePin.confirm')), '1357');
    await tester.tap(find.byKey(const Key('changePin.submit')));
    await settle(tester);
    expect(find.text('Account PIN changed'), findsOneWidget);

    await tester.tap(find.byKey(const Key('account.lock')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('accountLock.pin')), '1357');
    await tester.tap(find.byKey(const Key('accountLock.submit')));
    await settle(tester);
    expect(find.byType(AccountScreen), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('an auto-lock covers the screen; unlocking returns to it as it was', (WidgetTester tester) async {
    final AccountProvider account = await pumpApp(tester);
    await tester.runAsync(() => account.signIn(email: 'ana@example.com', password: 'correct horse battery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home.account')));
    await settle(tester);
    await createPin(tester);
    await tester.tap(find.byKey(const Key('account.report')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('report.subject')), 'Half-written report');

    // What the 5-minute timer does.
    AccountLockScope.read(tester.element(find.byType(ReportScreen))).lock();
    await tester.pumpAndSettle();
    expect(find.text('Account locked'), findsOneWidget);
    expect(find.text('Half-written report'), findsNothing, reason: 'hidden while locked');

    await tester.enterText(find.byKey(const Key('accountLock.pin')), '2468');
    await tester.tap(find.byKey(const Key('accountLock.submit')));
    await settle(tester);
    expect(find.byType(ReportScreen), findsOneWidget);
    expect(find.text('Half-written report'), findsOneWidget, reason: 'the draft survived');
    await teardown(tester);
  });
}
