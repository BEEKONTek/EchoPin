import 'dart:convert';

import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_echopin_server.dart';
import '../helpers/memory_kv_store.dart';

void main() {
  late FakeEchoPinServer server;
  late MemoryKvStore kv;

  AccountProvider make() => AccountProvider(
    kv: kv,
    platform: 'Android',
    appVersion: '0.4.0',
    api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
  );

  setUp(() async {
    server = await FakeEchoPinServer.start();
    kv = MemoryKvStore();
  });

  test('without a server URL accounts are off and nothing changes', () async {
    final AccountProvider a = AccountProvider(kv: kv, platform: 'Linux', appVersion: '0.4.0', serverUrl: '');
    await a.load();
    expect(a.enabled, isFalse);
    expect(a.stage, AccountStage.disabled);
  });

  test('sign-in proves the device key and survives a restart offline', () async {
    final AccountProvider a = make();
    await a.load();
    expect(a.stage, AccountStage.signedOut);
    await a.signIn(email: 'Ana@Example.com', password: 'correct horse battery');
    expect(a.stage, AccountStage.signedIn);
    expect(a.account!.displayName, 'Ana');
    expect(a.escrow?.keyId, server.escrowKeyId, reason: 'escrow key cached at sign-in');

    server.offline = true;
    final AccountProvider again = make();
    await again.load();
    expect(again.stage, AccountStage.signedIn, reason: 'offline-first: still signed in');
    expect(again.escrow?.keyId, server.escrowKeyId, reason: 'can seal logs with no signal');
    expect(server.loginKeys.toSet(), hasLength(1));
  });

  test('two-step sign-in asks for the code, then succeeds', () async {
    server.totpRequired = true;
    final AccountProvider a = make();
    await a.load();
    await expectLater(
      a.signIn(email: 'ana@example.com', password: 'correct horse battery'),
      throwsA(isA<AccountError>().having((AccountError e) => e.code, 'code', 'totp_required')),
    );
    await a.signIn(email: 'ana@example.com', password: 'correct horse battery', totp: '123456');
    expect(a.signedIn, isTrue);
  });

  test('wrong password is a sentence, not a stack trace', () async {
    final AccountProvider a = make();
    await a.load();
    await expectLater(
      a.signIn(email: 'ana@example.com', password: 'nope nope nope'),
      throwsA(isA<AccountError>().having((AccountError e) => e.message, 'message',
          'That email and password do not match')),
    );
  });

  test('expired access refreshes once, even for concurrent requests', () async {
    final AccountProvider a = make();
    await a.load();
    await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
    server.expireAccessTokens();
    final List<Map<String, dynamic>> results = await Future.wait(<Future<Map<String, dynamic>>>[
      a.authed('GET', '/v1/me'),
      a.authed('GET', '/v1/me'),
      a.authed('GET', '/v1/me'),
    ]);
    expect(results.every((Map<String, dynamic> r) => r['email'] == 'ana@example.com'), isTrue);
    expect(server.refreshCount, 1, reason: 'a second refresh with the same token looks like theft');
  });

  test('a refused refresh signs the device out and says why', () async {
    final AccountProvider a = make();
    await a.load();
    await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
    server.expireAccessTokens();
    server.refreshRefusal = 'session_revoked';
    await expectLater(a.authed('GET', '/v1/me'), throwsA(isA<AccountError>()));
    expect(a.stage, AccountStage.signedOut);
    expect(a.signedOutReason, contains('signed out'));
    expect(await kv.read('echo_pin.account_v1'), isNull, reason: 'tokens wiped');
  });

  test('a removed device signs in again with a fresh key', () async {
    final AccountProvider a = make();
    await a.load();
    await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
    final String firstKey = server.loginKeys.single;
    await a.signOut();
    server.revokedDeviceKeys.add(firstKey);
    await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
    expect(a.signedIn, isTrue);
    expect(server.loginKeys.last, isNot(firstKey));
  });

  test('weak passwords are caught before any request', () async {
    final AccountProvider a = make();
    await a.load();
    server.offline = true;
    await expectLater(
      a.signUp(email: 'ana@example.com', password: 'short', displayName: 'Ana'),
      throwsA(isA<AccountError>().having((AccountError e) => e.code, 'code', 'weak_password')),
    );
  });

  test('offline is its own error with a plain message', () async {
    final AccountProvider a = make();
    await a.load();
    server.offline = true;
    await expectLater(
      a.signIn(email: 'ana@example.com', password: 'correct horse battery'),
      throwsA(isA<OfflineError>()),
    );
  });

  test('refresh subject matches the server definition', () {
    // Server: base64Url(SHA-256(token)); see AuthService.refreshSubject.
    expect(AccountProvider.refreshSubject('abc'), 'ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0=');
    expect(base64Url.decode(AccountProvider.refreshSubject('x')), hasLength(32));
    expect(ProtocolLimits.minPasswordLength, 10);
  });

  group('clock and transport safety', () {
    test('a phone clock 20 minutes off still signs in and refreshes', () async {
      server.serverSkew = const Duration(minutes: 20);
      final AccountProvider a = make();
      await a.load(); // /v1/config teaches the app the server's clock
      await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
      expect(a.signedIn, isTrue);
      server.expireAccessTokens();
      await a.refreshMe();
      expect(server.refreshCount, 1);
      expect(a.signedIn, isTrue);
    });

    test('first contact with a wrong clock: one automatic retry fixes it', () async {
      server.serverSkew = const Duration(minutes: -30);
      final AccountProvider a = make(); // no load(): offset still unknown
      await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
      expect(a.signedIn, isTrue);
      expect(server.loginCount, 2);
    });

    test('a refused proof keeps the session instead of signing out', () async {
      final AccountProvider a = make();
      await a.load();
      await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
      server.expireAccessTokens();
      server.refreshRefusal = 'device_proof_invalid';
      await expectLater(a.refreshMe(), throwsA(isA<AccountError>()));
      expect(a.signedIn, isTrue, reason: 'refresh token was not consumed; fix the cause and retry');
    });

    test('HTTP dates parse; release builds refuse plain http to remote hosts', () {
      expect(parseHttpDate('Sun, 08 Nov 2026 10:00:05 GMT'), DateTime.utc(2026, 11, 8, 10, 0, 5));
      expect(parseHttpDate('yesterday'), isNull);
      expect(serverUrlAllowed('https://echopin.example.org'), isTrue);
      expect(serverUrlAllowed('http://localhost:8080'), isTrue);
      expect(serverUrlAllowed('ftp://x'), isFalse);
      expect(serverUrlAllowed(''), isFalse);
    });
  });

  test('the device tells the server whether its key is in secure storage', () async {
    final AccountProvider a = AccountProvider(
      kv: kv,
      platform: 'Linux',
      appVersion: '0.4.0',
      secureKeyStorage: false,
      api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
    );
    await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
    expect(server.lastDevice!['secureStorage'], isFalse);
  });
}
