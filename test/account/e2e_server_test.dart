import 'dart:convert';
import 'dart:io';

import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/api_client.dart';
import 'package:echo_pin/account/outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_kv_store.dart';

/// The app's real account code against a real running EchoPin server.
///
///     ECHOPIN_E2E_URL=http://127.0.0.1:18080 \
///     ECHOPIN_E2E_EMAIL=ops@example.org ECHOPIN_E2E_PASSWORD=... \
///     flutter test test/account/e2e_server_test.dart
///
/// The account must be an admin (create it with `echopin_admin create-admin`).
/// Skipped when the variables are not set.
void main() {
  final Map<String, String> env = Platform.environment;
  final String? url = env['ECHOPIN_E2E_URL'];
  final String? email = env['ECHOPIN_E2E_EMAIL'];
  final String? password = env['ECHOPIN_E2E_PASSWORD'];
  final String? skip = (url == null || email == null || password == null)
      ? 'Set ECHOPIN_E2E_URL, ECHOPIN_E2E_EMAIL and ECHOPIN_E2E_PASSWORD'
      : null;

  test(
    'sign in, seal, upload, break-glass open, refresh, audit',
    skip: skip,
    () async {
      final MemoryKvStore kv = MemoryKvStore();
      AccountProvider make() => AccountProvider(
        kv: kv,
        platform: 'Linux',
        appVersion: '0.4.0',
        api: EchoPinApi(baseUrl: url!),
      );

      final AccountProvider account = make();
      await account.load();
      await account.signIn(email: email!, password: password!);
      expect(account.account!.isAdmin, isTrue);
      expect(await account.ensureEscrow(), isNotNull);

      final Outbox outbox = Outbox(kv: kv, account: account);
      await outbox.load();
      final String sessionId =
          'E2E${DateTime.now().millisecondsSinceEpoch % 100000}';
      final String marker =
          'sealed-by-the-app-${DateTime.now().microsecondsSinceEpoch}';
      final String logId = await outbox.enqueue(
        OutboxKind.sessionLog,
        <String, dynamic>{
          'sessionId': sessionId,
          'sessionName': 'End to end',
          'startedAt': DateTime.now().toUtc().toIso8601String(),
          'sosCount': 1,
          'sequence': 1,
          'final': true,
          'plain': <String, Object?>{'marker': marker, 'events': <Object?>[]},
        },
      );
      await outbox.enqueue(OutboxKind.report, <String, dynamic>{
        'category': 'safety',
        'severity': 'critical',
        'subject': 'E2E report',
        'body': 'Filed by the app end-to-end test',
        'sessionId': sessionId,
      });
      await outbox.enqueue(OutboxKind.diagnostics, <String, dynamic>{
        'level': 'info',
        'appVersion': '0.4.0',
        'platform': 'Linux',
        'summary': 'E2E diagnostics',
        'payload': <String, Object?>{'radios': 'loopback: up'},
      });
      expect(
        await outbox.flush(),
        isTrue,
        reason: 'rejected: ${outbox.lastRejection}',
      );

      final Map<String, dynamic> index = await account.authed(
        'GET',
        '/v1/admin/sessions?sessionId=$sessionId',
      );
      expect((index['sessions'] as List<dynamic>).single['sos'], 1);

      final Map<String, dynamic> opened = await account.authed(
        'POST',
        '/v1/admin/session-logs/$logId/unseal',
        body: <String, Object?>{
          'reason': 'End-to-end verification of sealing',
          'caseRef': 'E2E',
        },
      );
      expect(
        opened['content']['marker'],
        marker,
        reason: 'app sealing ⇄ server opening agree',
      );

      // Force the refresh path: a dead access token in storage.
      final Map<String, dynamic> stored =
          jsonDecode(kv.data['echo_pin.account_v1']!) as Map<String, dynamic>;
      (stored['tokens'] as Map<String, dynamic>)['accessToken'] =
          'not-a-real-token';
      kv.data['echo_pin.account_v1'] = jsonEncode(stored);
      final AccountProvider restarted = make();
      await restarted.load();
      final Map<String, dynamic> me = await restarted.authed('GET', '/v1/me');
      expect(
        me['email'],
        email.toLowerCase().trim() == me['email'] ? me['email'] : email,
      );

      final Map<String, dynamic> audit = await restarted.authed(
        'GET',
        '/v1/admin/audit/verify',
      );
      expect(audit['ok'], isTrue);
      final Map<String, dynamic> entries = await restarted.authed(
        'GET',
        '/v1/admin/audit?action=session_log',
      );
      expect(
        (entries['entries'] as List<dynamic>).first['detail']['reason'],
        'End-to-end verification of sealing',
      );

      await restarted.signOut();
      outbox.dispose();
    },
  );
}
