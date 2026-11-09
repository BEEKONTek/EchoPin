import 'dart:convert';
import 'dart:io';

import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:echopin_server/echopin_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:echopin_server/src/backup/backup_store.dart';

import 'fake_supabase_storage.dart';
import 'helpers.dart';

void main() {
  late TestEnv env;

  setUpAll(() async {
    if (testAdminUrl != null) env = await TestEnv.create();
  });
  tearDownAll(() async {
    if (testAdminUrl != null) await env.dispose();
  });

  group('registration and sign-in', skip: skipWithoutDb, () {
    test('register → verify → sign in → me', () async {
      final TestUser u = await env.signUp('Thandi@Example.com', name: 'Thandi');
      final ApiResult me = await env.call('GET', '/v1/me', token: u.accessToken);
      expect(me.status, 200);
      expect(me.map['email'], 'Thandi@Example.com');
      expect(me.map['role'], 'member');
      expect(me.map['totpEnabled'], isFalse);
    });

    test('registering a taken email looks identical and changes nothing', () async {
      await env.signUp('taken@example.com');
      final ApiResult r = await env.call('POST', '/v1/auth/register', body: <String, Object?>{
        'email': 'taken@example.com',
        'password': 'another strong pass',
        'displayName': 'Imposter',
      });
      expect(r.status, 202);
      expect(r.map['status'], 'verification_sent');
      expect(env.mailer.sent.last.subject, contains('tried to create'));
      final ApiResult bad = await env.login('taken@example.com', 'another strong pass', await TestDevice.create());
      expect(bad.error, 'invalid_credentials');
    });

    test('weak passwords and bad emails get precise messages', () async {
      final ApiResult weak = await env.call('POST', '/v1/auth/register', body: <String, Object?>{
        'email': 'w@example.com', 'password': 'short', 'displayName': 'W'});
      expect(weak.error, 'weak_password');
      expect(weak.map['message'], contains('at least 10'));
      final ApiResult email = await env.call('POST', '/v1/auth/register', body: <String, Object?>{
        'email': 'not-an-email', 'password': 'correct horse battery', 'displayName': 'W'});
      expect(email.error, 'invalid_email');
    });

    test('unverified accounts cannot sign in; wrong codes count down', () async {
      await env.call('POST', '/v1/auth/register', body: <String, Object?>{
        'email': 'pending@example.com', 'password': 'correct horse battery', 'displayName': 'P'});
      final ApiResult l = await env.login('pending@example.com', 'correct horse battery', await TestDevice.create());
      expect(l.error, 'email_unverified');
      final String right = env.mailer.lastCodeFor('pending@example.com')!;
      final String wrong = right == '000000' ? '111111' : '000000';
      final ApiResult v = await env.call('POST', '/v1/auth/verify-email',
          body: <String, Object?>{'email': 'pending@example.com', 'code': wrong, 'password': 'correct horse battery'});
      expect(v.error, 'invalid_code');
      // No "4 tries left": that would confirm the address has an account.
      expect(v.map.containsKey('attemptsRemaining'), isFalse);
    });

    test('a bad device signature is refused even with the right password', () async {
      final TestUser u = await env.signUp('proof@example.com');
      final TestDevice d = await TestDevice.create();
      final int ts = env.clock.now.millisecondsSinceEpoch;
      final ApiResult r = await env.call('POST', '/v1/auth/login', body: <String, Object?>{
        'email': u.email,
        'password': u.password,
        'device': <String, Object?>{
          'publicKey': base64.encode(d.publicKey), 'label': 'x', 'platform': 'Android'},
        'proofTimestamp': ts,
        // Signed for a different email.
        'proofSignature': base64.encode(await d.sign('login', 'someone@else.com', ts)),
      });
      expect(r.error, 'device_proof_invalid');
    });

    test('five wrong passwords lock the account, then it unlocks with time', () async {
      final TestUser u = await env.signUp('lock@example.com');
      final TestDevice d = await TestDevice.create();
      for (int i = 0; i < 5; i++) {
        expect((await env.login(u.email, 'wrong password!!', d, )).error, 'invalid_credentials');
      }
      final ApiResult locked = await env.login(u.email, u.password, d);
      expect(locked.status, 423);
      expect(locked.error, 'locked');
      env.clock.advance(const Duration(minutes: 16));
      expect((await env.login(u.email, u.password, d)).status, 200);
    });
  });

  group('tokens', skip: skipWithoutDb, () {
    test('refresh rotates; the old access token stops working', () async {
      final TestUser u = await env.signUp('rotate@example.com');
      final String oldAccess = u.accessToken;
      final ApiResult r = await env.refresh(u);
      expect(r.status, 200);
      u.take(r.map);
      expect((await env.call('GET', '/v1/me', token: oldAccess)).status, 401);
      expect((await env.call('GET', '/v1/me', token: u.accessToken)).status, 200);
    });

    test('replaying a used refresh token signs the device out (theft detection)', () async {
      final TestUser u = await env.signUp('reuse@example.com');
      final String stolen = u.refreshToken;
      final ApiResult first = await env.refresh(u);
      u.take(first.map);
      final ApiResult replay = await env.refresh(u, refreshToken: stolen);
      expect(replay.error, 'session_revoked');
      // The legitimate holder's newer tokens were revoked too.
      expect((await env.call('GET', '/v1/me', token: u.accessToken)).status, 401);
      expect((await env.refresh(u)).status, 401);
      final ApiResult audit = await env.call('GET', '/v1/admin/audit', token: u.accessToken);
      expect(audit.status, 401);
      final Row? row = await env.db.one(
          "select count(*)::int as n from audit_log where action = 'auth.refresh_reuse_detected'");
      expect(row!['n'], greaterThanOrEqualTo(1));
    });

    test('a refresh token is useless without the device key', () async {
      final TestUser u = await env.signUp('bound@example.com');
      final ApiResult r = await env.refresh(u, device: await TestDevice.create());
      expect(r.error, 'device_proof_invalid');
    });

    test('revoking a device ends its sessions and blocks re-login with that key', () async {
      final TestUser u = await env.signUp('devices@example.com');
      final ApiResult list = await env.call('GET', '/v1/me/devices', token: u.accessToken);
      expect((list.map['devices'] as List).single['current'], isTrue);
      final ApiResult del = await env.call('DELETE', '/v1/me/devices/${u.deviceId}', token: u.accessToken);
      expect(del.status, 200);
      expect((await env.call('GET', '/v1/me', token: u.accessToken)).status, 401);
      expect((await env.login(u.email, u.password, u.device)).error, 'device_revoked');
    });
  });

  group('two-step sign-in', skip: skipWithoutDb, () {
    test('setup → enable → required at login → replay refused → disable', () async {
      final TestUser u = await env.signUp('totp@example.com');
      final ApiResult setup = await env.call('POST', '/v1/me/totp/setup', token: u.accessToken);
      expect(setup.status, 200);
      expect(setup.map['otpauthUri'], startsWith('otpauth://totp/EchoPin'));
      final List<int> secret = _base32Decode(setup.map['secret'] as String);
      String code() => Totp.codeAt(secret, Totp.stepAt(env.clock.now));

      expect((await env.call('POST', '/v1/me/totp/enable', token: u.accessToken,
          body: <String, Object?>{'code': '000000', 'password': u.password})).error, anyOf('totp_invalid', isNull));
      // A stolen session alone (no password) cannot attach an authenticator.
      expect((await env.call('POST', '/v1/me/totp/enable', token: u.accessToken,
          body: <String, Object?>{'code': code(), 'password': 'not the password'})).error, 'wrong_password');
      expect((await env.call('POST', '/v1/me/totp/enable', token: u.accessToken,
          body: <String, Object?>{'code': code(), 'password': u.password})).status, 200);

      env.clock.advance(const Duration(seconds: 30));
      final ApiResult need = await env.login(u.email, u.password, u.device);
      expect(need.error, 'totp_required');
      final String c = code();
      expect((await env.login(u.email, u.password, u.device, totp: c)).status, 200);
      // Same code again within its window: refused as a replay.
      expect((await env.login(u.email, u.password, u.device, totp: c)).error, 'totp_invalid');

      env.clock.advance(const Duration(seconds: 30));
      final ApiResult relog = await env.login(u.email, u.password, u.device, totp: code());
      u.take(relog.map);
      env.clock.advance(const Duration(seconds: 30));
      expect((await env.call('POST', '/v1/me/totp/disable', token: u.accessToken,
          body: <String, Object?>{'password': u.password, 'code': code()})).status, 200);
      env.clock.advance(const Duration(seconds: 30));
      expect((await env.login(u.email, u.password, u.device)).status, 200);
    });
  });

  group('password reset', skip: skipWithoutDb, () {
    test('reset with an emailed code signs out every device', () async {
      final TestUser u = await env.signUp('reset@example.com');
      await env.call('POST', '/v1/auth/password/forgot', body: <String, Object?>{'email': u.email});
      final String code = env.mailer.lastCodeFor(u.email)!;
      final ApiResult r = await env.call('POST', '/v1/auth/password/reset', body: <String, Object?>{
        'email': u.email, 'code': code, 'newPassword': 'a brand new phrase'});
      expect(r.status, 200);
      expect((await env.call('GET', '/v1/me', token: u.accessToken)).status, 401);
      expect((await env.login(u.email, 'a brand new phrase', u.device)).status, 200);
    });
  });

  group('reports, diagnostics and sealed logs', skip: skipWithoutDb, () {
    late TestUser member;
    late TestUser responder;
    late TestUser admin;
    late String logId;

    setUpAll(() async {
      if (testAdminUrl == null) return;
      member = await env.signUp('member@example.com', name: 'Sipho');
      responder = await env.signUp('responder@example.com', name: 'Rescue Lead');
      admin = await env.signUp('admin@example.com', name: 'Admin');
      await env.setRole(responder.email, AccountRole.responder);
      await env.setRole(admin.email, AccountRole.admin);
    });

    test('members cannot reach the console', () async {
      expect((await env.call('GET', '/v1/admin/overview', token: member.accessToken)).error, 'forbidden');
      expect((await env.call('GET', '/v1/admin/accounts', token: responder.accessToken)).error, 'forbidden');
    });

    test('devices upload diagnostics and a sealed log; ingest cannot read it', () async {
      final ApiResult cfg = await env.call('GET', '/v1/config');
      final Map<String, dynamic> escrow = cfg.map['escrow'] as Map<String, dynamic>;
      logId = '0b6f0b8e-6a0e-4f43-9a55-2f5d8f0c1a01';
      final List<int> sealed = await SealedBox.seal(
        recipientPublicKey: base64.decode(escrow['publicKey'] as String),
        plaintext: utf8.encode(jsonEncode(<String, Object?>{
          'events': <Object?>[
            <String, Object?>{'type': SessionLogEvent.sosRaised, 'at': '2026-11-07T10:00:00Z', 'by': 'Sipho'},
          ],
        })),
        context: 'session-log:$logId',
      );
      final Map<String, Object?> body = <String, Object?>{
        'id': logId,
        'sessionId': 'HIKE42',
        'sessionName': 'Table Mountain',
        'startedAt': env.clock.now.subtract(const Duration(hours: 2)).toIso8601String(),
        'endedAt': env.clock.now.toIso8601String(),
        'memberCount': 4,
        'sosCount': 1,
        'helpCount': 1,
        'keyId': escrow['keyId'],
        'sealed': base64.encode(sealed),
      };
      final ApiResult up = await env.call('POST', '/v1/session-logs', token: member.accessToken, body: body);
      expect(up.status, 201);
      final ApiResult again = await env.call('POST', '/v1/session-logs', token: member.accessToken, body: body);
      expect(again.map['status'], 'duplicate');

      final ApiResult wrongKey = await env.call('POST', '/v1/session-logs', token: member.accessToken,
          body: <String, Object?>{...body, 'id': '0b6f0b8e-6a0e-4f43-9a55-2f5d8f0c1a02', 'keyId': 'ffffffffffffffff'});
      expect(wrongKey.error, 'unknown_escrow_key');

      final ApiResult diag = await env.call('POST', '/v1/diagnostics', token: member.accessToken, body: <String, Object?>{
        'level': 'error', 'appVersion': '0.4.0', 'platform': 'Android',
        'summary': 'Bluetooth transport failed', 'payload': <String, Object?>{'radios': 'BLE: down'}});
      expect(diag.status, 201);
    });

    test('safety reports are never below high and reach the console first', () async {
      final ApiResult low = await env.call('POST', '/v1/reports', token: member.accessToken, body: <String, Object?>{
        'category': 'safety', 'severity': 'low', 'subject': 'Lost contact', 'body': 'Lost Sipho near the ridge', 'sessionId': 'HIKE42'});
      expect(low.status, 201);
      expect(low.map['severity'], 'high');
      await env.call('POST', '/v1/reports', token: member.accessToken, body: <String, Object?>{
        'category': 'bug', 'subject': 'Map is slow', 'body': 'It lags'});
      final ApiResult crit = await env.call('POST', '/v1/reports', token: member.accessToken, body: <String, Object?>{
        'category': 'safety', 'severity': 'critical', 'subject': 'Injured', 'body': 'Ankle'});
      final ApiResult list = await env.call('GET', '/v1/admin/reports', token: responder.accessToken);
      final List<dynamic> reports = list.map['reports'] as List<dynamic>;
      expect(reports.first['id'], crit.map['id']);
      expect(reports.map((dynamic r) => r['severity']), containsAllInOrder(<String>['critical', 'high', 'normal']));

      final String id = low.map['id'] as String;
      final ApiResult close = await env.call('PATCH', '/v1/admin/reports/$id', token: responder.accessToken,
          body: <String, Object?>{'status': 'resolved'});
      expect(close.error, 'invalid_input');
      await env.call('POST', '/v1/admin/reports/$id/notes', token: responder.accessToken,
          body: <String, Object?>{'body': 'Called the group lead'});
      final ApiResult done = await env.call('PATCH', '/v1/admin/reports/$id', token: responder.accessToken,
          body: <String, Object?>{'status': 'resolved', 'resolution': 'Found safe', 'assignToMe': true});
      expect(done.map['status'], 'resolved');
      expect(done.map['assignee'], 'Rescue Lead');
      expect((done.map['notes'] as List).single['body'], 'Called the group lead');

      final ApiResult mine = await env.call('GET', '/v1/me/reports', token: member.accessToken);
      expect((mine.map['reports'] as List).firstWhere((dynamic r) => r['id'] == id)['resolution'], 'Found safe');
    });

    test('break-glass needs a reason, leaves a trace, then shows the log', () async {
      final ApiResult index = await env.call('GET', '/v1/admin/sessions?sos=true', token: responder.accessToken);
      final Map<String, dynamic> s = (index.map['sessions'] as List).single as Map<String, dynamic>;
      expect(s['sessionId'], 'HIKE42');
      expect(s['sos'], 1);
      expect(s['people'], contains('Sipho'));

      final ApiResult noReason = await env.call('POST', '/v1/admin/session-logs/$logId/unseal',
          token: responder.accessToken, body: <String, Object?>{'reason': 'because'});
      expect(noReason.error, 'reason_required');
      expect((await env.call('POST', '/v1/admin/session-logs/$logId/unseal',
          token: member.accessToken, body: <String, Object?>{'reason': 'I am curious about it'})).error, 'forbidden');

      final ApiResult open = await env.call('POST', '/v1/admin/session-logs/$logId/unseal',
          token: responder.accessToken,
          body: <String, Object?>{'reason': 'Member reported missing near the ridge', 'caseRef': 'SAR-118'});
      expect(open.status, 200);
      expect((open.map['content']['events'] as List).single['type'], SessionLogEvent.sosRaised);

      final ApiResult detail = await env.call('GET', '/v1/admin/sessions/HIKE42', token: responder.accessToken);
      final Map<String, dynamic> access = (detail.map['accessHistory'] as List).single as Map<String, dynamic>;
      expect(access['by'], 'Rescue Lead');
      expect(access['caseRef'], 'SAR-118');

      final ApiResult audit = await env.call('GET', '/v1/admin/audit?action=session_log', token: admin.accessToken);
      final Map<String, dynamic> entry = (audit.map['entries'] as List).first as Map<String, dynamic>;
      expect(entry['action'], 'session_log.unsealed');
      expect(entry['detail']['reason'], 'Member reported missing near the ridge');
    });

    test('checkpoints during a session do not double-count in the index', () async {
      final ApiResult cfg = await env.call('GET', '/v1/config');
      final Map<String, dynamic> escrow = cfg.map['escrow'] as Map<String, dynamic>;
      Future<ApiResult> upload(String id, int seq, bool last) async {
        final List<int> sealed = await SealedBox.seal(
          recipientPublicKey: base64.decode(escrow['publicKey'] as String),
          plaintext: utf8.encode('{"events":[]}'),
          context: 'session-log:$id',
        );
        return env.call('POST', '/v1/session-logs', token: member.accessToken, body: <String, Object?>{
          'id': id,
          'sessionId': 'RIVER7',
          'sessionName': 'River walk',
          'startedAt': env.clock.now.toIso8601String(),
          'sosCount': 1,
          'sequence': seq,
          'final': last,
          'keyId': escrow['keyId'],
          'sealed': base64.encode(sealed),
        });
      }

      expect((await upload('1c6f0b8e-6a0e-4f43-9a55-2f5d8f0c1a01', 1, false)).status, 201);
      ApiResult index = await env.call('GET', '/v1/admin/sessions?sessionId=RIVER7', token: responder.accessToken);
      Map<String, dynamic> s = (index.map['sessions'] as List).single as Map<String, dynamic>;
      expect(s['finished'], isFalse, reason: 'only a checkpoint so far: the session is live');

      expect((await upload('1c6f0b8e-6a0e-4f43-9a55-2f5d8f0c1a02', 2, true)).status, 201);
      index = await env.call('GET', '/v1/admin/sessions?sessionId=RIVER7', token: responder.accessToken);
      s = (index.map['sessions'] as List).single as Map<String, dynamic>;
      expect(s['sos'], 1);
      expect(s['uploads'], 1);
      expect(s['finished'], isTrue);

      final ApiResult detail = await env.call('GET', '/v1/admin/sessions/RIVER7', token: responder.accessToken);
      expect((detail.map['logs'] as List).map((dynamic l) => l['sequence']), <int>[1, 2]);
    });

    test('overview counts everything across the board', () async {
      final ApiResult o = await env.call('GET', '/v1/admin/overview', token: admin.accessToken);
      expect(o.status, 200);
      expect(o.map['sessions']['withSos7d'], 2);
      expect(o.map['diagnostics24h']['errors'], 1);
      expect(o.map['reports']['critical'], 1);
      expect(o.map['daily'], hasLength(14));
      // The chart counts sessions, not uploads, so it agrees with the tile.
      expect((o.map['daily'] as List).fold<int>(0, (int n, dynamic d) => n + (d['sos'] as int)),
          o.map['sessions']['withSos7d']);
      expect((o.map['versions'] as List).first['platform'], 'Android');
    });

    test('admins manage accounts but cannot lock themselves out', () async {
      expect((await env.call('PATCH', '/v1/admin/accounts/${admin.accountId}', token: admin.accessToken,
          body: <String, Object?>{'role': 'member'})).error, 'self_change');
      final ApiResult disable = await env.call('PATCH', '/v1/admin/accounts/${member.accountId}',
          token: admin.accessToken, body: <String, Object?>{'status': 'disabled'});
      expect(disable.map['status'], 'disabled');
      expect((await env.call('GET', '/v1/me', token: member.accessToken)).status, 401);
      expect((await env.login(member.email, member.password, member.device)).error, 'account_disabled');
      await env.call('PATCH', '/v1/admin/accounts/${member.accountId}',
          token: admin.accessToken, body: <String, Object?>{'status': 'active'});

      final ApiResult accounts = await env.call('GET', '/v1/admin/accounts?q=sipho', token: admin.accessToken);
      expect((accounts.map['accounts'] as List).single['email'], 'member@example.com');
    });

    test('the audit chain verifies, and detects tampering', () async {
      final ApiResult ok = await env.call('GET', '/v1/admin/audit/verify', token: admin.accessToken);
      expect(ok.map['ok'], isTrue);
      expect(ok.map['checked'], greaterThan(5));

      await expectLater(
        env.db.execute("update audit_log set actor_label = 'x' where id = 1"),
        throwsA(anything),
      );
      // Someone with superuser rights goes around the trigger…
      await env.db.execute('alter table audit_log disable trigger audit_log_no_change');
      await env.db.execute(
          "update audit_log set detail = '{\"reason\":\"edited\"}' where action = 'session_log.unsealed'");
      await env.db.execute('alter table audit_log enable trigger audit_log_no_change');
      final ApiResult broken = await env.call('GET', '/v1/admin/audit/verify', token: admin.accessToken);
      expect(broken.map['ok'], isFalse);
      expect(broken.map['reason'], contains('altered'));
    });
  });

  group('security regressions', skip: skipWithoutDb, () {
    test('re-registering a pending email cannot hijack the victim\'s verification', () async {
      const String email = 'victim@example.com';
      await env.call('POST', '/v1/auth/register', body: <String, Object?>{
        'email': email, 'password': 'victim strong pass', 'displayName': 'Victim'});
      // The attacker re-registers the same address with their password.
      await env.call('POST', '/v1/auth/register', body: <String, Object?>{
        'email': email, 'password': 'attacker strong pass', 'displayName': 'Victim'});
      // The victim types the code from their inbox and their own password.
      final ApiResult v = await env.call('POST', '/v1/auth/verify-email', body: <String, Object?>{
        'email': email, 'code': env.mailer.lastCodeFor(email), 'password': 'victim strong pass'});
      expect(v.error, 'password_mismatch');
      // Nothing was activated, so the attacker's password is useless.
      final ApiResult l = await env.login(email, 'attacker strong pass', await TestDevice.create());
      expect(l.error, 'email_unverified');
    });

    test('parallel wrong passwords still trigger the lockout', () async {
      final TestUser u = await env.signUp('burst@example.com');
      final TestDevice d = await TestDevice.create();
      await Future.wait(<Future<ApiResult>>[
        for (int i = 0; i < 8; i++) env.login(u.email, 'wrong password $i!', d),
      ]);
      final Row r = (await env.db.one(
          "select failures from login_throttle where email = 'burst@example.com'"))!;
      // Before the fix all eight read 0 and wrote 1. Requests that arrive
      // after the lock is set are refused as locked without counting.
      expect(r['failures'], greaterThanOrEqualTo(AuthService.lockAfterFailures));
      expect((await env.login(u.email, u.password, d)).error, 'locked');
      // The owner's own phone is not locked out by a stranger's guesses.
      expect((await env.login(u.email, u.password, u.device)).status, 200);
    });

    test('at most ten codes a day per account, counted in the database', () async {
      final TestUser u = await env.signUp('codes@example.com');
      final Row a = (await env.db.one(
          "select id from accounts where email_normalized = 'codes@example.com'"))!;
      for (int i = 0; i < AuthService.maxCodesPerDay; i++) {
        await env.db.execute(
          '''insert into email_codes (account_id, purpose, code_hash, expires_at, created_at, used_at)
             values (@a::uuid, 'reset', decode('00', 'hex'), @t, @t, @t)''',
          <String, Object?>{'a': a['id'], 't': env.clock.now},
        );
      }
      final int before = env.mailer.sent.length;
      final ApiResult r = await env.call('POST', '/v1/auth/password/forgot',
          body: <String, Object?>{'email': u.email});
      expect(r.status, 202, reason: 'same answer as always: no account enumeration');
      expect(env.mailer.sent.length, before, reason: 'but no eleventh code is sent');
    });

    test('a spoofed X-Forwarded-For does not change the recorded address', () {
      Request req(Map<String, String> h) => Request('GET', Uri.parse('http://x/'), headers: h);
      const ClientIpPolicy oneProxy = ClientIpPolicy(trustProxy: true);
      // The client wrote 6.6.6.6; our proxy appended the real 81.1.1.1.
      expect(clientIp(req(<String, String>{'x-forwarded-for': '6.6.6.6, 81.1.1.1'}), policy: oneProxy), '81.1.1.1');
      const ClientIpPolicy render = ClientIpPolicy(trustProxy: true, header: 'true-client-ip');
      expect(
        clientIp(req(<String, String>{
          'x-forwarded-for': '6.6.6.6, 81.1.1.1, 172.71.0.1, 10.0.0.1',
          'true-client-ip': '81.1.1.1',
        }), policy: render),
        '81.1.1.1',
      );
      expect(clientIp(req(<String, String>{'x-forwarded-for': '6.6.6.6'}), policy: const ClientIpPolicy()),
          'unknown', reason: 'headers are ignored unless a proxy is trusted');
    });

    test('the audit chain only verifies with the server key', () async {
      await env.signUp('chain@example.com'); // guarantees some audit rows
      final AuditLog forger = AuditLog(macKey: List<int>.filled(32, 7));
      expect((await forger.verify(env.db)).ok, isFalse,
          reason: 'without ECHOPIN_KEYS nobody can produce matching hashes');
    });

    test('an admin can reset a lost authenticator; the person is signed out', () async {
      final TestUser admin = await env.signUp('reset-admin@example.com');
      await env.setRole(admin.email, AccountRole.admin);
      final TestUser u = await env.signUp('lost-phone@example.com');
      final ApiResult setup = await env.call('POST', '/v1/me/totp/setup', token: u.accessToken);
      final List<int> secret = _base32Decode(setup.map['secret'] as String);
      await env.call('POST', '/v1/me/totp/enable', token: u.accessToken, body: <String, Object?>{
        'code': Totp.codeAt(secret, Totp.stepAt(env.clock.now)), 'password': u.password});
      final Row a = (await env.db.one(
          "select id from accounts where email_normalized = 'lost-phone@example.com'"))!;
      final ApiResult r = await env.call('PATCH', '/v1/admin/accounts/${a['id']}',
          token: admin.accessToken, body: <String, Object?>{'resetTwoStep': true});
      expect(r.status, 200, reason: r.body.toString());
      expect(r.map['totpEnabled'], isFalse);
      expect((await env.call('GET', '/v1/me', token: u.accessToken)).status, 401);
      expect((await env.login(u.email, u.password, u.device)).status, 200);
    });
  });

  group('hardening', skip: skipWithoutDb, () {
    late TestUser member;
    late TestUser outsider;
    late TestUser responder;
    late TestUser admin;

    setUpAll(() async {
      if (testAdminUrl == null) return;
      member = await env.signUp('h-member@example.com', name: 'Lindiwe');
      outsider = await env.signUp('h-outsider@example.com', name: 'Mallory');
      responder = await env.signUp('h-responder@example.com', name: 'Medic');
      admin = await env.signUp('h-admin@example.com', name: 'Boss');
      await env.setRole(responder.email, AccountRole.responder);
      await env.setRole(admin.email, AccountRole.admin);
    });

    Future<Map<String, Object?>> sealedBody({
      required String id,
      required String sessionId,
      List<int>? tag,
      bool custodian = true,
    }) async {
      final Map<String, dynamic> escrow =
          (await env.call('GET', '/v1/config')).map['escrow'] as Map<String, dynamic>;
      List<int> payload = utf8.encode(jsonEncode(<String, Object?>{'note': 'inner secret'}));
      String? custodianKeyId;
      if (custodian) {
        final Map<String, dynamic> c = escrow['custodian'] as Map<String, dynamic>;
        custodianKeyId = c['keyId'] as String;
        payload = await SealedBox.seal(
          recipientPublicKey: base64.decode(c['publicKey'] as String),
          plaintext: payload,
          context: 'session-log-custodian:$id',
        );
      }
      final List<int> outer = await SealedBox.seal(
        recipientPublicKey: base64.decode(escrow['publicKey'] as String),
        plaintext: payload,
        context: 'session-log:$id',
      );
      return <String, Object?>{
        'id': id,
        'sessionId': sessionId,
        'sessionName': 'Night walk',
        'startedAt': env.clock.now.toIso8601String(),
        'keyId': escrow['keyId'],
        'sealed': base64.encode(outer),
        'custodianKeyId': ?custodianKeyId,
        if (tag != null) 'sessionTag': base64.encode(tag),
      };
    }

    test('double-sealed records: the server hands back only the inner seal', () async {
      const String id = '1c2d3e4f-0000-4000-8000-000000000001';
      final List<int> tag = List<int>.filled(16, 7);
      expect((await env.call('POST', '/v1/session-logs', token: member.accessToken,
          body: await sealedBody(id: id, sessionId: 'WALK01', tag: tag))).status, 201);
      final ApiResult bad = await env.call('POST', '/v1/session-logs', token: member.accessToken,
          body: <String, Object?>{
            ...await sealedBody(id: '1c2d3e4f-0000-4000-8000-000000000009', sessionId: 'WALK01'),
            'custodianKeyId': 'ffffffffffffffff',
          });
      expect(bad.error, 'unknown_custodian_key');

      final ApiResult open = await env.call('POST', '/v1/admin/session-logs/$id/unseal',
          token: responder.accessToken, body: <String, Object?>{'reason': 'Lindiwe pressed SOS at 22:10'});
      expect(open.status, 200);
      expect(open.map.containsKey('content'), isFalse, reason: 'the server cannot read it');
      final List<int> clear = await SealedBox.open(
        recipient: env.custodian,
        sealed: base64.decode(open.map['sealedInner'] as String),
        context: 'session-log-custodian:$id',
      );
      expect(jsonDecode(utf8.decode(clear))['note'], 'inner secret');

      // Every admin is told, by email, who opened what and why.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final Iterable<OutgoingMail> alerts =
          env.mailer.sent.where((OutgoingMail m) => m.subject.contains('opened a session record'));
      expect(alerts.map((OutgoingMail m) => m.to), contains(admin.email));
      expect(alerts.any((OutgoingMail m) => m.text.contains('Lindiwe pressed SOS at 22:10')), isTrue);
    });

    test('an upload without the session tag is flagged as unproven', () async {
      final List<int> tag = List<int>.filled(16, 7);
      await env.call('POST', '/v1/session-logs', token: member.accessToken,
          body: await sealedBody(id: '1c2d3e4f-0000-4000-8000-000000000002', sessionId: 'WALK02', tag: tag));
      // Someone who only saw the public session id over Bluetooth.
      await env.call('POST', '/v1/session-logs', token: outsider.accessToken,
          body: await sealedBody(id: '1c2d3e4f-0000-4000-8000-000000000003', sessionId: 'WALK02',
              tag: List<int>.filled(16, 9)));
      await env.call('POST', '/v1/session-logs', token: responder.accessToken,
          body: await sealedBody(id: '1c2d3e4f-0000-4000-8000-000000000004', sessionId: 'WALK02', tag: tag));
      final ApiResult index = await env.call('GET', '/v1/admin/sessions?sessionId=WALK02', token: responder.accessToken);
      expect((index.map['sessions'] as List).single['unproven'], isTrue);
      final ApiResult detail = await env.call('GET', '/v1/admin/sessions/WALK02', token: responder.accessToken);
      final Map<String, bool?> proven = <String, bool?>{
        for (final dynamic l in detail.map['logs'] as List) l['displayName'] as String: l['memberProven'] as bool?,
      };
      expect(proven, <String, bool?>{'Lindiwe': true, 'Mallory': false, 'Medic': true});
      expect((detail.map['logs'] as List).first.containsKey('email'), isFalse,
          reason: 'responders see names, not email addresses');
    });

    test('a tie in session tags marks nobody; extra uploads do not outvote people', () async {
      final List<int> real = List<int>.filled(16, 3);
      final List<int> fake = List<int>.filled(16, 4);
      await env.call('POST', '/v1/session-logs', token: member.accessToken,
          body: await sealedBody(id: '1c2d3e4f-0000-4000-8000-000000000011', sessionId: 'TIE01', tag: real));
      // The outsider sends three uploads: still one person, one vote.
      for (int i = 2; i <= 4; i++) {
        await env.call('POST', '/v1/session-logs', token: outsider.accessToken,
            body: await sealedBody(id: '1c2d3e4f-0000-4000-8000-00000000001$i', sessionId: 'TIE01', tag: fake));
      }
      ApiResult d = await env.call('GET', '/v1/admin/sessions/TIE01', token: responder.accessToken);
      expect((d.map['logs'] as List).map((dynamic l) => l['memberProven']).toSet(), <Object?>{null},
          reason: '1 person vs 1 person: no guess, so the real record is never branded fake');
      expect((d.map['logs'] as List).first['tagsDisagree'], isTrue);
      // A second genuine member breaks the tie.
      await env.call('POST', '/v1/session-logs', token: responder.accessToken,
          body: await sealedBody(id: '1c2d3e4f-0000-4000-8000-000000000015', sessionId: 'TIE01', tag: real));
      d = await env.call('GET', '/v1/admin/sessions/TIE01', token: responder.accessToken);
      final Map<String, Set<Object?>> byName = <String, Set<Object?>>{};
      for (final dynamic l in d.map['logs'] as List) {
        byName.putIfAbsent(l['displayName'] as String, () => <Object?>{}).add(l['memberProven']);
      }
      expect(byName, <String, Set<Object?>>{'Lindiwe': <Object?>{true}, 'Mallory': <Object?>{false}, 'Medic': <Object?>{true}});
    });

    test('one SOS seen by two phones counts once in the index', () async {
      for (final (String id, TestUser u) in <(String, TestUser)>[
        ('1c2d3e4f-0000-4000-8000-000000000021', member),
        ('1c2d3e4f-0000-4000-8000-000000000022', responder),
      ]) {
        await env.call('POST', '/v1/session-logs', token: u.accessToken, body: <String, Object?>{
          ...await sealedBody(id: id, sessionId: 'SOS01', tag: List<int>.filled(16, 5)),
          'sosCount': 1,
        });
      }
      final ApiResult idx = await env.call('GET', '/v1/admin/sessions?sessionId=SOS01', token: responder.accessToken);
      expect((idx.map['sessions'] as List).single['sos'], 1);
    });

        test('looking a person up is audited', () async {
      await env.call('GET', '/v1/admin/sessions?q=lindiwe', token: responder.accessToken);
      final ApiResult audit = await env.call('GET', '/v1/admin/audit?action=sessions.searched', token: admin.accessToken);
      expect((audit.map['entries'] as List).first['detail']['query'], 'lindiwe');
    });

    test('unknown emails lock exactly like real ones', () async {
      final TestDevice d = await TestDevice.create();
      for (int i = 0; i < AuthService.lockAfterFailures; i++) {
        await env.login('nobody-here@example.com', 'wrong password!!', d);
      }
      final ApiResult ghost = await env.login('nobody-here@example.com', 'wrong password!!', d);
      expect(ghost.status, 423);
      expect(ghost.error, 'locked');
    });

    test('devices without a keystore get 7-day sessions', () async {
      final TestDevice d = await TestDevice.create();
      final int ts = env.clock.now.millisecondsSinceEpoch;
      final ApiResult r = await env.call('POST', '/v1/auth/login', body: <String, Object?>{
        'email': member.email,
        'password': member.password,
        'device': <String, Object?>{
          'publicKey': base64.encode(d.publicKey), 'label': 'Old tablet', 'platform': 'Linux',
          'secureStorage': false},
        'proofTimestamp': ts,
        'proofSignature': base64.encode(await d.sign('login', member.email, ts)),
      });
      expect(r.status, 200, reason: r.body.toString());
      final DateTime exp = DateTime.parse(r.map['refreshExpiresAt'] as String);
      expect(exp.difference(env.clock.now).inDays, lessThanOrEqualTo(7));
    });

    test('rate limits live in the database and survive a restart', () async {
      final DbRateLimiter a = DbRateLimiter(env.db, clock: env.clock.call);
      expect(await a.hit('t:restart', limit: 2, window: const Duration(minutes: 10)), isNull);
      expect(await a.hit('t:restart', limit: 2, window: const Duration(minutes: 10)), isNull);
      final DbRateLimiter afterRestart = DbRateLimiter(env.db, clock: env.clock.call);
      expect(await afterRestart.hit('t:restart', limit: 2, window: const Duration(minutes: 10)), isNotNull);
    });

    test('retention removes old data and records what it removed', () async {
      await env.db.execute(
        '''insert into diagnostics (level, app_version, platform, summary, payload, received_at)
           values ('info', '0.1', 'Linux', 'ancient', '{}'::jsonb, @t)''',
        <String, Object?>{'t': env.clock.now.subtract(const Duration(days: 400))},
      );
      final RetentionService r = RetentionService(
        db: env.db,
        config: ServerConfig(databaseUrl: env.url),
        audit: AuditLog(macKey: env.server.keys.auditMacKey, clock: env.clock.call),
        clock: env.clock.call,
      );
      final Map<String, int> removed = await r.run();
      expect(removed['diagnostics'], greaterThanOrEqualTo(1));
      final ApiResult audit = await env.call('GET', '/v1/admin/audit?action=retention', token: admin.accessToken);
      expect((audit.map['entries'] as List).first['action'], 'retention.purged');
    });

    test('a chain cut short of the recorded anchor fails verification', () async {
      final AuditLog log = AuditLog(macKey: env.server.keys.auditMacKey);
      final AuditVerification cut = await log.verify(env.db, anchorId: 1 << 40, anchorHash: 'ab');
      expect(cut.ok, isFalse);
      expect(cut.reason, contains('removed from the end'));
    });
  });

  group('supabase data API lock-down', skip: skipWithoutDb, () {
    test('anon/authenticated lose every grant and RLS is on, server still works', () async {
      // Recreate Supabase's setup: the roles exist and hold full grants.
      for (final String role in <String>['anon', 'authenticated']) {
        await env.db.execute(
          "do \$\$ begin create role $role nologin; exception when duplicate_object then null; end \$\$");
        await env.db.execute('grant all on all tables in schema public to $role');
        await env.db.execute('grant all on all sequences in schema public to $role');
      }
      await env.db.execute('alter table accounts disable row level security');
      expect((await env.db.one("select has_table_privilege('anon', 'accounts', 'select') as p"))!['p'], isTrue);

      await migrate(env.db); // the lock-down runs after every migration pass

      for (final String role in <String>['anon', 'authenticated']) {
        final Row? open = await env.db.one('''
          select count(*)::int as n from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r'
             and (has_table_privilege(@r, c.oid, 'select,insert,update,delete,truncate')
                  or not c.relrowsecurity)''', <String, Object?>{'r': role});
        expect(open!['n'], 0, reason: '$role still reaches a table');
      }
      // The owner bypasses RLS: the API keeps working.
      final TestUser u = await env.signUp('rls-check@example.org');
      expect(u.accessToken, isNotEmpty);
    });
  });

  group('backups', skip: skipWithoutDb, () {
    test('backup → verify → restore into a fresh database', () async {
      final TestUser a = await env.signUp('backup-admin@example.com', name: 'Backup Admin');
      await env.setRole(a.email, AccountRole.admin);
      final ApiResult run = await env.call('POST', '/v1/admin/backups', token: a.accessToken);
      expect(run.status, 201, reason: '$run');
      final String file = '${env.backupsDir.path}/${run.map['fileName']}';
      expect(File(file).existsSync(), isTrue);
      expect(File(file).readAsBytesSync().sublist(0, 4), utf8.encode('EPBK'));

      final int objects = await env.server.backups.verifyFile(file);
      expect(objects, greaterThan(10));

      final String target = 'echopin_restore_${DateTime.now().microsecondsSinceEpoch}';
      final Db adminDb = Db.connect(testAdminUrl!);
      await adminDb.execute('create database $target');
      final String targetUrl = Uri.parse(testAdminUrl!).replace(path: '/$target').toString();
      try {
        await env.server.backups.restoreFile(file, databaseUrl: targetUrl);
        final Db restored = Db.connect(targetUrl);
        final Row? r = await restored.one(
            "select count(*)::int as n from accounts where email_normalized = 'backup-admin@example.com'");
        expect(r!['n'], 1);
        expect((await AuditLog(macKey: env.server.keys.auditMacKey).verify(restored)).ok, isFalse,
            reason: 'the chain was deliberately broken by the previous test');
        await restored.close();
      } finally {
        await adminDb.execute('drop database if exists $target with (force)');
        await adminDb.close();
      }

      final ApiResult list = await env.call('GET', '/v1/admin/backups', token: a.accessToken);
      expect((list.map['backups'] as List).first['status'], 'ok');
      expect((list.map['backups'] as List).first['onDisk'], isTrue);
    });

    test('hosted: backup to Supabase Storage, then verify and restore by name', () async {
      final FakeSupabaseStorage storage = FakeSupabaseStorage(key: 'sb_secret_test');
      final BackupService hosted = BackupService(
        db: env.db,
        keys: env.server.keys,
        config: ServerConfig(databaseUrl: env.url, backupsDir: Directory.systemTemp.path),
        audit: AuditLog(macKey: env.server.keys.auditMacKey),
        store: SupabaseBackupStore(
          url: 'https://abc.supabase.co',
          key: 'sb_secret_test',
          bucket: 'echopin-backups',
          client: storage.client,
          partSize: 16 * 1024, // force several parts
        ),
      );
      await hosted.store.ensureReady();
      final Map<String, Object?> r = await hosted.run(kind: 'manual', actor: const AuditActor.system('test'));
      final String name = r['fileName']! as String;
      expect(storage.objects.keys.where((String k) => k.contains(name)).length, greaterThan(1));
      expect(File('${Directory.systemTemp.path}/$name').existsSync(), isFalse, reason: 'nothing left on disk');

      expect(await hosted.verifyFile(name), greaterThan(10));

      final String target = 'echopin_hosted_${DateTime.now().microsecondsSinceEpoch}';
      final Db adminDb = Db.connect(testAdminUrl!);
      await adminDb.execute('create database $target');
      final String targetUrl = Uri.parse(testAdminUrl!).replace(path: '/$target').toString();
      try {
        // A non-EchoPin schema, like Supabase's own, must survive a restore.
        final Db t = Db.connect(targetUrl);
        await t.execute('create schema auth');
        await t.execute('create table auth.users (id int)');
        await t.execute('insert into auth.users values (1)');
        await hosted.restoreFile(name, databaseUrl: targetUrl);
        expect((await t.one('select count(*)::int as n from accounts'))!['n'], greaterThan(0));
        expect((await t.one('select count(*)::int as n from auth.users'))!['n'], 1);
        // In place, over existing EchoPin tables, works too.
        await hosted.restoreFile(name, databaseUrl: targetUrl);
        await t.close();
      } finally {
        await adminDb.execute('drop database if exists $target with (force)');
        await adminDb.close();
      }

      // One running backup at a time, across instances sharing the database.
      await env.db.execute(
        "insert into backups (kind, status, started_at) values ('manual', 'running', now())",
      );
      await expectLater(
        hosted.run(kind: 'manual', actor: const AuditActor.system('test')),
        throwsA(isA<ApiException>().having((ApiException e) => e.code, 'code', 'backup_running')),
      );
      await env.db.execute("update backups set status = 'failed' where status = 'running'");
    });

    test('a wrong storage key is recorded on the backup, not only in host logs', () async {
      final FakeSupabaseStorage storage = FakeSupabaseStorage(key: 'sb_secret_right');
      final BackupService wrong = BackupService(
        db: env.db,
        keys: env.server.keys,
        config: ServerConfig(databaseUrl: env.url, backupsDir: Directory.systemTemp.path),
        audit: AuditLog(macKey: env.server.keys.auditMacKey),
        store: SupabaseBackupStore(
          url: 'https://abc.supabase.co',
          key: 'sb_publishable_oops', // the classic mix-up
          bucket: 'echopin-backups',
          client: storage.client,
        ),
      );
      await expectLater(
        wrong.run(kind: 'manual', actor: const AuditActor.system('test')),
        throwsA(isA<ApiException>().having((ApiException e) => e.code, 'code', 'backup_failed')),
      );
      // (Other tests run on a simulated clock, so match on the reason
      // rather than on "latest".)
      final Row? recorded = await env.db.one(
        "select count(*)::int as n from backups where status = 'failed' and error like '%401%Invalid API key%'",
      );
      expect(recorded!['n'], 1);
    });
  });
}

List<int> _base32Decode(String s) {
  const String alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final List<int> out = <int>[];
  int buffer = 0, bits = 0;
  for (final int c in s.codeUnits) {
    buffer = (buffer << 5) | alphabet.indexOf(String.fromCharCode(c));
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return out;
}
