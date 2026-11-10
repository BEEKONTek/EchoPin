import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/providers/account_lock_provider.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_echopin_server.dart';
import '../helpers/memory_kv_store.dart';

void main() {
  late FakeEchoPinServer server;
  late MemoryKvStore kv;
  late DateTime now;

  AccountProvider account() => AccountProvider(
    kv: kv,
    platform: 'Android',
    appVersion: '0.4.0',
    api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
  );

  AccountLockProvider lockFor(AccountProvider a) => AccountLockProvider(
    auth: AdminAuthService.account(
      kv: kv,
      iterations: 10,
      useIsolate: false,
      lockoutDuration: const Duration(seconds: 30),
      clock: () => now,
    ),
    account: a,
    clock: () => now,
  );

  /// Lets listener-started async work (PIN wipes, refresh) finish.
  Future<void> idle() => Future<void>.delayed(const Duration(milliseconds: 20));

  Future<(AccountProvider, AccountLockProvider)> signedIn() async {
    final AccountProvider a = account();
    final AccountLockProvider lock = lockFor(a);
    await a.load();
    await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
    await idle();
    return (a, lock);
  }

  setUp(() async {
    server = await FakeEchoPinServer.start();
    kv = MemoryKvStore();
    now = DateTime(2026, 11, 10, 9);
  });

  test('a fresh sign-in asks for a new PIN; creating it unlocks', () async {
    final (_, AccountLockProvider lock) = await signedIn();
    expect(lock.hasPin, isFalse);
    expect(lock.isUnlocked, isFalse);
    await lock.createPin('2468');
    expect(lock.isUnlocked, isTrue);
    expect(kv.data.values.join(' ').contains('2468'), isFalse, reason: 'stored hashed');
    expect(() => lock.createPin('1357'), throwsStateError, reason: 'cannot overwrite');
  });

  test('the PIN survives a restart, and the app starts locked', () async {
    final (_, AccountLockProvider lock) = await signedIn();
    await lock.createPin('2468');

    final AccountProvider again = account();
    final AccountLockProvider lock2 = lockFor(again);
    await again.load();
    await idle();
    expect(again.signedIn, isTrue);
    expect(lock2.hasPin, isTrue, reason: 'restoring a sign-in is not a new one');
    expect(lock2.isUnlocked, isFalse);
    expect((await lock2.unlock('2468')).ok, isTrue);
    expect(lock2.isUnlocked, isTrue);
  });

  test('admin and account PINs are separate', () async {
    final (_, AccountLockProvider lock) = await signedIn();
    await lock.createPin('2468');
    final AdminAuthService admin = AdminAuthService(kv: kv, iterations: 10, useIsolate: false);
    expect(await admin.hasPin(), isFalse);
    await admin.setPin('9999');
    expect((await lock.unlock('9999')).ok, isFalse);
  });

  test('locks after 5 idle minutes; a touch postpones it; resume checks the clock', () async {
    final (_, AccountLockProvider lock) = await signedIn();
    await lock.createPin('2468');
    now = now.add(const Duration(minutes: 4));
    lock.touch();
    now = now.add(const Duration(minutes: 4));
    lock.checkIdle();
    expect(lock.isUnlocked, isTrue, reason: '4 minutes since the last touch');
    now = now.add(const Duration(minutes: 2));
    lock.checkIdle(); // e.g. the app came back from the background
    expect(lock.isUnlocked, isFalse);
  });

  test('signing out wipes the PIN; signing in again asks for a new one', () async {
    final (AccountProvider a, AccountLockProvider lock) = await signedIn();
    await lock.createPin('2468');
    await a.signOut();
    await idle();
    expect(lock.isUnlocked, isFalse);
    expect(lock.hasPin, isFalse);
    expect(kv.data.keys.where((String k) => k.startsWith('echo_pin.account_')), isEmpty);

    await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
    await idle();
    expect(lock.hasPin, isFalse);
  });

  test('forgot PIN signs out', () async {
    final (AccountProvider a, AccountLockProvider lock) = await signedIn();
    await lock.createPin('2468');
    lock.lock();
    await lock.forgotPin();
    await idle();
    expect(a.signedIn, isFalse);
    expect(lock.hasPin, isFalse);
  });

  test('the third lockout in a row signs the account out, with a reason', () async {
    final (AccountProvider a, AccountLockProvider lock) = await signedIn();
    await lock.createPin('2468');
    lock.lock();
    Future<AdminAuthResult> fiveWrong() async {
      AdminAuthResult r = await lock.unlock('0000');
      for (int i = 0; i < 4; i++) {
        r = await lock.unlock('0000');
      }
      return r;
    }

    AdminAuthResult r = await fiveWrong();
    expect(r.status, AdminAuthStatus.lockedOut);
    expect(r.lockouts, 1);
    // Refused while locked out, even with the right PIN.
    expect((await lock.unlock('2468')).status, AdminAuthStatus.lockedOut);

    now = now.add(const Duration(seconds: 31));
    r = await fiveWrong();
    expect(r.lockouts, 2);
    expect(a.signedIn, isTrue);

    now = now.add(const Duration(seconds: 31));
    r = await fiveWrong();
    expect(r.lockouts, 3);
    await idle();
    expect(a.signedIn, isFalse);
    expect(a.signedOutReason, AccountLockProvider.tooManyAttemptsReason);
    expect(lock.hasPin, isFalse);
  });

  test('a correct PIN resets the lockout count', () async {
    final (_, AccountLockProvider lock) = await signedIn();
    await lock.createPin('2468');
    lock.lock();
    for (int i = 0; i < 5; i++) {
      await lock.unlock('0000');
    }
    now = now.add(const Duration(seconds: 31));
    expect((await lock.unlock('2468')).ok, isTrue);
    lock.lock();
    final AdminAuthResult r = await lock.unlock('0000');
    expect(r.lockouts, 0);
    expect(r.attemptsRemaining, 4);
  });

  test('changing the PIN needs the current one and an unlocked account', () async {
    final (_, AccountLockProvider lock) = await signedIn();
    await lock.createPin('2468');
    expect((await lock.changePin('0000', '1357')).ok, isFalse);
    expect((await lock.changePin('2468', '1357')).ok, isTrue);
    lock.lock();
    expect(() => lock.changePin('1357', '9753'), throwsA(isA<AccountLockedException>()));
    expect((await lock.unlock('1357')).ok, isTrue);
  });
}
