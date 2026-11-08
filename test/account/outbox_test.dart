import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:cryptography/cryptography.dart';
import 'dart:convert';
import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/account/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_echopin_server.dart';
import '../helpers/memory_kv_store.dart';

void main() {
  late FakeEchoPinServer server;
  late MemoryKvStore kv;
  late AccountProvider account;

  Future<AccountProvider> signedIn() async {
    final AccountProvider a = AccountProvider(
      kv: kv,
      platform: 'Android',
      appVersion: '0.4.0',
      api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
    );
    await a.load();
    await a.signIn(email: 'ana@example.com', password: 'correct horse battery');
    await a.ensureEscrow();
    return a;
  }

  Map<String, dynamic> logBody(String marker) => <String, dynamic>{
    'sessionId': 'HIKE42',
    'sessionName': 'Ridge',
    'startedAt': DateTime.utc(2026, 11, 7, 9).toIso8601String(),
    'sosCount': 1,
    'plain': <String, Object?>{'marker': marker, 'events': <Object?>[]},
  };

  setUp(() async {
    server = await FakeEchoPinServer.start();
    kv = MemoryKvStore();
    account = await signedIn();
  });

  test(
    'logs are sealed at enqueue; the server can open them, plain text never travels',
    () async {
      final Outbox outbox = Outbox(kv: kv, account: account);
      await outbox.load();
      await outbox.enqueue(OutboxKind.sessionLog, logBody('first'));
      expect(
        outbox.items.single.body.containsKey('plain'),
        isFalse,
        reason: 'sealed before storage',
      );
      expect(await outbox.flush(), isTrue);
      final Map<String, dynamic> uploaded = server.sessionLogs.single;
      expect(uploaded['keyId'], server.escrowKeyId);
      expect((await server.open(uploaded))['marker'], 'first');
    },
  );

  test(
    'offline keeps everything, across restarts, until it can be sent',
    () async {
      final Outbox outbox = Outbox(kv: kv, account: account);
      await outbox.load();
      server.offline = true;
      await outbox.enqueue(OutboxKind.report, <String, dynamic>{
        'category': 'safety',
        'subject': 'Lost',
        'body': 'Lost near ridge',
      });
      await outbox.enqueue(OutboxKind.sessionLog, logBody('offline'));
      expect(await outbox.flush(), isFalse);
      expect(outbox.pendingCount, 2);

      final Outbox later = Outbox(kv: kv, account: account);
      await later.load();
      expect(later.pendingCount, 2, reason: 'persisted in the keystore');
      server.offline = false;
      expect(await later.flush(), isTrue);
      expect(server.reports.single['subject'], 'Lost');
      expect(
        (await server.open(server.sessionLogs.single))['marker'],
        'offline',
      );
    },
  );

  test(
    'a log queued before the escrow key is known is sealed once it arrives',
    () async {
      // A device that has never reached the server: no cached escrow key.
      final MemoryKvStore fresh = MemoryKvStore();
      server.offline = true;
      final AccountProvider a = AccountProvider(
        kv: fresh,
        platform: 'Android',
        appVersion: '0.4.0',
        api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
      );
      // Copy the signed-in session over, but not the escrow key.
      fresh.data['echo_pin.account_v1'] = kv.data['echo_pin.account_v1']!;
      await a.load();
      expect(a.escrow, isNull);
      final Outbox outbox = Outbox(kv: fresh, account: a);
      await outbox.load();
      await outbox.enqueue(OutboxKind.sessionLog, logBody('late-seal'));
      expect(outbox.items.single.body.containsKey('plain'), isTrue);

      server.offline = false;
      expect(await outbox.flush(), isTrue);
      expect(
        (await server.open(server.sessionLogs.single))['marker'],
        'late-seal',
      );
    },
  );

  test('server errors back off; refusals are dropped and remembered', () async {
    final Outbox outbox = Outbox(kv: kv, account: account);
    await outbox.load();
    await outbox.enqueue(OutboxKind.diagnostics, <String, dynamic>{
      'level': 'info',
    });
    server.failNextUploadWith = 503;
    expect(await outbox.flush(), isFalse);
    expect(outbox.items.single.attempts, 1);
    expect(
      outbox.items.single.nextAttemptAt!.isAfter(DateTime.now().toUtc()),
      isTrue,
    );
    expect(
      await outbox.flush(),
      isFalse,
      reason: 'not retried before the backoff',
    );
    expect(server.diagnostics, isEmpty);

    await outbox.enqueue(OutboxKind.report, <String, dynamic>{
      'category': 'bug',
    });
    server.failNextUploadWith = 400;
    await outbox.flush();
    expect(outbox.rejectedCount, 1);
    expect(outbox.lastRejection, contains('report'));
    expect(outbox.items.map((OutboxItem i) => i.kind), <OutboxKind>[
      OutboxKind.diagnostics,
    ]);
  });

  test('another account’s items stay put', () async {
    final Outbox outbox = Outbox(kv: kv, account: account);
    await outbox.load();
    await outbox.enqueue(OutboxKind.report, <String, dynamic>{
      'category': 'bug',
    });
    kv.data['echo_pin.outbox_v1'] = kv.data['echo_pin.outbox_v1']!.replaceAll(
      '"accountId":"acct-1"',
      '"accountId":"someone-else"',
    );
    final Outbox reloaded = Outbox(kv: kv, account: account);
    await reloaded.load();
    expect(await reloaded.flush(), isTrue);
    expect(server.reports, isEmpty);
    expect(reloaded.pendingCount, 1);
  });

  test('over the cap, routine diagnostics are dropped first', () async {
    final Outbox outbox = Outbox(kv: kv, account: account, maxItems: 3);
    await outbox.load();
    server.offline = true;
    await outbox.enqueue(OutboxKind.diagnostics, <String, dynamic>{'n': 1});
    await outbox.enqueue(OutboxKind.report, <String, dynamic>{'n': 2});
    await outbox.enqueue(OutboxKind.sessionLog, logBody('keep'));
    await outbox.enqueue(OutboxKind.report, <String, dynamic>{'n': 4});
    expect(outbox.items.map((OutboxItem i) => i.kind), <OutboxKind>[
      OutboxKind.report,
      OutboxKind.sessionLog,
      OutboxKind.report,
    ]);
  });

  test('uuids are version 4', () {
    expect(
      newUuid(),
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });

  group('custodian (second seal)', () {
    test(
      'with a custodian key, logs are sealed twice and the server alone cannot read them',
      () async {
        await server.enableCustodian();
        await account.ensureEscrow();
        final Outbox outbox = Outbox(kv: kv, account: account);
        await outbox.load();
        await outbox.enqueue(OutboxKind.sessionLog, logBody('double'));
        await outbox.flush();
        final Map<String, dynamic> log = server.sessionLogs.single;
        expect(log['custodianKeyId'], isNotNull);
        // The server's own key only reveals another sealed box.
        final List<int> outerOnly = await SealedBox.open(
          recipient: server.escrow,
          sealed: base64.decode(log['sealed'] as String),
          context: 'session-log:${log['id']}',
        );
        expect(String.fromCharCodes(outerOnly).contains('double'), isFalse);
        // Server layer + custodian layer together open it.
        expect((await server.open(log))['marker'], 'double');
      },
    );

    test(
      'once seen, the custodian key is never dropped by a later config',
      () async {
        await server.enableCustodian();
        await account.ensureEscrow();
        final String id = account.escrow!.custodianKeyId!;
        server.custodianPublic = null; // a compromised server "forgets" it
        await account.ensureEscrow();
        expect(account.escrow!.custodianKeyId, id);
      },
    );

    test('a custodian key built into the app wins over the server', () async {
      final SimpleKeyPair pinned = await X25519().newKeyPair();
      final List<int> pub = (await pinned.extractPublicKey()).bytes;
      await server.enableCustodian(); // server offers a different one
      final AccountProvider a = AccountProvider(
        kv: MemoryKvStore(),
        platform: 'Android',
        appVersion: '0.4.0',
        pinnedCustodianKey: base64.encode(pub),
        api: EchoPinApi(baseUrl: 'https://echopin.test', client: server.client),
      );
      await a.ensureEscrow();
      expect(a.escrow!.custodianKeyId, SealedBox.keyIdFor(pub));
    });

    test(
      'a responder imports the custodian key and opens the inner seal locally',
      () async {
        final SimpleKeyPair kp = await X25519().newKeyPair();
        final List<int> seed = await kp.extractPrivateKeyBytes();
        final List<int> pub = (await kp.extractPublicKey()).bytes;
        final String id = await account.importCustodianKey(
          'ECHOPIN-CUSTODIAN-1:${base64Url.encode(seed)}',
        );
        expect(id, SealedBox.keyIdFor(pub));
        expect(await account.custodianKeyIds(), <String>[id]);
        final List<int> inner = await SealedBox.seal(
          recipientPublicKey: pub,
          plaintext: utf8.encode(
            jsonEncode(<String, Object?>{'events': <Object?>[]}),
          ),
          context: 'session-log-custodian:L1',
        );
        final Map<String, dynamic>? content = await account.openInnerSeal(
          logId: 'L1',
          custodianKeyId: id,
          sealedInner: inner,
        );
        expect(content, isNotNull);
        expect(
          await account.openInnerSeal(
            logId: 'L1',
            custodianKeyId: 'other',
            sealedInner: inner,
          ),
          isNull,
        );
        await expectLater(
          account.importCustodianKey('garbage'),
          throwsA(isA<AccountError>()),
        );
      },
    );
  });
}
