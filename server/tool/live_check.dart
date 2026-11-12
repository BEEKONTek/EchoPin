// SYSTEM TEST: drives a running EchoPin server through every hardened
// flow over plain HTTP, exactly as phones and the console would: sign-up
// with breached-password refusal and uniform timing, email codes, lockouts,
// known-device bypass, staff two-step, device revocation, sealed uploads
// with the custodian double seal, break-glass unseal, alert mail and the
// audit chain. Each check prints PASS or FAIL; the exit code is 1 if any
// failed.
//
// Run it with `tool/live_check.sh`, which starts a throwaway PostgreSQL
// and server with fresh keys. By hand it needs:
//   ECHOPIN_LIVE_URL  the server (default http://127.0.0.1:18080)
//   SERVER_LOG        the server's log; the console mailer writes codes there
//   CUSTODIAN_FILE    the `ECHOPIN-CUSTODIAN-1:…` private key
// and an admin `boss@example.org` with the password used below.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:echopin_server/echopin_server.dart' show Totp;
import 'package:http/http.dart' as http;

final String base =
    Platform.environment['ECHOPIN_LIVE_URL'] ?? 'http://127.0.0.1:18080';
final String logPath = Platform.environment['SERVER_LOG']!;
final String custodianPrivate = File(
  Platform.environment['CUSTODIAN_FILE']!,
).readAsStringSync().trim();
int passed = 0, failed = 0;

void check(String what, bool ok, [Object? detail]) {
  ok ? passed++ : failed++;
  stdout.writeln(
    '${ok ? 'PASS' : 'FAIL'}  $what${ok || detail == null ? '' : '\n      → $detail'}',
  );
}

class R {
  R(this.status, this.body, this.ms);
  final int status;
  final Map<String, dynamic> body;
  final int ms;
  String? get error => body['error'] as String?;
  @override
  String toString() => '$status $body';
}

Future<R> call(
  String method,
  String path, {
  Object? body,
  String? token,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  final http.Request req = http.Request(method, Uri.parse('$base$path'));
  req.headers['content-type'] = 'application/json';
  if (token != null) req.headers['authorization'] = 'Bearer $token';
  if (body != null) req.body = jsonEncode(body);
  final http.Response res = await http.Response.fromStream(await req.send());
  final Object? j = res.body.isEmpty ? null : jsonDecode(res.body);
  return R(
    res.statusCode,
    j is Map<String, dynamic> ? j : <String, dynamic>{},
    sw.elapsedMilliseconds,
  );
}

/// Newest 8-digit code mailed to [email], read from the server log.
/// The newest code the console mailer logged for [email], once at least
/// [atLeast] have been logged. Mail goes out in the background, so this
/// polls (up to 10 s) rather than assuming a fixed delay.
Future<String?> codeFor(String email, {int atLeast = 1}) async {
  final RegExp block = RegExp(
    '→ ${RegExp.escape(email)}\\n  Subject: [^\\n]*?(\\d{8})',
  );
  for (int i = 0; i < 100; i++) {
    final List<RegExpMatch> m = block
        .allMatches(File(logPath).readAsStringSync())
        .toList();
    if (m.length >= atLeast) return m.last.group(1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

class Device {
  Device(this.kp, this.pub);
  final SimpleKeyPair kp;
  final List<int> pub;
  static Future<Device> create() async {
    final SimpleKeyPair kp = await Ed25519().newKeyPair();
    return Device(kp, (await kp.extractPublicKey()).bytes);
  }
}

Future<R> login(String email, String password, Device d, {String? totp}) async {
  final int ts = DateTime.now().toUtc().millisecondsSinceEpoch;
  final List<int> sig = await DeviceProof.sign(
    deviceKey: d.kp,
    purpose: 'login',
    subject: email,
    timestampMs: ts,
  );
  return call(
    'POST',
    '/v1/auth/login',
    body: <String, Object?>{
      'email': email,
      'password': password,
      'totp': ?totp,
      'device': <String, Object?>{
        'publicKey': base64.encode(d.pub),
        'label': 'Driver',
        'platform': 'Linux',
      },
      'proofTimestamp': ts,
      'proofSignature': base64.encode(sig),
    },
  );
}

Future<String> enableTwoStep(String token, String password) async {
  final R setup = await call('POST', '/v1/me/totp/setup', token: token);
  final String secretB32 = setup.body['secret'] as String;
  final List<int> secret = _b32(secretB32);
  final String code = Totp.codeAt(secret, Totp.stepAt(DateTime.now()));
  final R noPw = await call(
    'POST',
    '/v1/me/totp/enable',
    token: token,
    body: <String, Object?>{'code': code, 'password': 'wrong one entirely'},
  );
  check(
    'two-step: enabling with a wrong password is refused',
    noPw.error == 'wrong_password',
    noPw,
  );
  final R on = await call(
    'POST',
    '/v1/me/totp/enable',
    token: token,
    body: <String, Object?>{'code': code, 'password': password},
  );
  check('two-step: enabled with password + code', on.status == 200, on);
  return secretB32;
}

Future<void> main() async {
  final Device phone = await Device.create();
  const String email = 'thandi@example.org';
  const String pw = 'Blue kettle on the ridge 1987';

  // ── Breached password ──────────────────────────────────────────────────
  final R breached = await call(
    'POST',
    '/v1/auth/register',
    body: <String, Object?>{
      'email': 'breach@example.org',
      'password': 'password12345678',
      'displayName': 'B',
    },
  );
  check(
    'breached password "password12345678" refused (HIBP)',
    breached.error == 'breached_password',
    breached,
  );

  // ── Registration: uniform timing, 8-digit code, password-bound confirm ─
  final R reg = await call(
    'POST',
    '/v1/auth/register',
    body: <String, Object?>{
      'email': email,
      'password': pw,
      'displayName': 'Thandi',
    },
  );
  check('register answers 202', reg.status == 202, reg);
  check(
    'register takes ≥ 600 ms (uniform timing)',
    reg.ms >= 590,
    '${reg.ms} ms',
  );
  final R regAgain = await call(
    'POST',
    '/v1/auth/register',
    body: <String, Object?>{
      'email': 'boss@example.org',
      'password': 'Another long phrase 9911',
      'displayName': 'X',
    },
  );
  check(
    'registering a taken email looks the same (202, ≥ 600 ms)',
    regAgain.status == 202 && regAgain.ms >= 590,
    regAgain,
  );
  final String? code1 = await codeFor(email);
  check('emailed code is 8 digits', code1 != null && code1.length == 8, code1);

  final R wrongPw = await call(
    'POST',
    '/v1/auth/verify-email',
    body: <String, Object?>{
      'email': email,
      'code': code1,
      'password': 'Not the sign-up phrase 22',
    },
  );
  check(
    'confirm with the right code but another password → password_mismatch (anti pre-hijack)',
    wrongPw.error == 'password_mismatch',
    wrongPw,
  );
  final R bogus = await call(
    'POST',
    '/v1/auth/verify-email',
    body: <String, Object?>{'email': email, 'code': '00000000', 'password': pw},
  );
  final R ghost = await call(
    'POST',
    '/v1/auth/verify-email',
    body: <String, Object?>{
      'email': 'nobody@example.org',
      'code': '00000000',
      'password': pw,
    },
  );
  check(
    'wrong code: one generic answer, no "tries left"',
    bogus.error == 'invalid_code' &&
        !bogus.body.containsKey('attemptsRemaining'),
    bogus,
  );
  check(
    'unknown email gets the identical answer',
    ghost.error == bogus.error &&
        ghost.body['message'] == bogus.body['message'],
    ghost,
  );

  await call(
    'POST',
    '/v1/auth/resend-code',
    body: <String, Object?>{'email': email},
  );
  final String? code2 = await codeFor(email, atLeast: 2);
  final R ok = await call(
    'POST',
    '/v1/auth/verify-email',
    body: <String, Object?>{'email': email, 'code': code2, 'password': pw},
  );
  check(
    'confirm with fresh code + sign-up password → verified',
    ok.status == 200,
    ok,
  );

  // ── Lockout ─────────────────────────────────────────────────────────────
  final R first = await login(email, pw, phone);
  check('sign in on her phone', first.status == 200, first);
  final Device stranger = await Device.create();
  for (int i = 0; i < 5; i++) {
    await login(email, 'guess number $i here!', stranger);
  }
  final R locked = await login(email, pw, stranger);
  check(
    'after 5 wrong guesses, a NEW device is locked (423)',
    locked.status == 423,
    locked,
  );
  final R own = await login(email, pw, phone);
  check(
    'her OWN phone still signs in (known-device bypass)',
    own.status == 200,
    own,
  );
  for (int i = 0; i < 5; i++) {
    await login('ghost-person@example.org', 'guess number $i here!', stranger);
  }
  final R ghostLock = await login(
    'ghost-person@example.org',
    'guess number 9 here!',
    stranger,
  );
  check(
    'an email with NO account locks identically (no enumeration)',
    ghostLock.status == 423 && ghostLock.error == locked.error,
    ghostLock,
  );

  // ── Staff two-step ───────────────────────────────────────────────────────
  final Device bossPhone = await Device.create();
  const String bossPw = 'Admin unique phrase 4471 zebra';
  R boss = await login('boss@example.org', bossPw, bossPhone);
  String bossToken = boss.body['accessToken'] as String;
  final R blocked = await call('GET', '/v1/admin/overview', token: bossToken);
  check(
    'admin WITHOUT two-step is refused by the console',
    blocked.error == 'two_step_required',
    blocked,
  );
  final String bossSecret = await enableTwoStep(bossToken, bossPw);
  final R overview = await call('GET', '/v1/admin/overview', token: bossToken);
  check(
    'after turning on two-step the console answers',
    overview.status == 200,
    overview,
  );

  // Make Thandi a responder; she also needs two-step.
  String thandiToken = own.body['accessToken'] as String;
  final String thandiId =
      (own.body['account'] as Map<String, dynamic>)['id'] as String;
  await call(
    'PATCH',
    '/v1/admin/accounts/$thandiId',
    token: bossToken,
    body: <String, Object?>{'role': 'responder'},
  );
  await enableTwoStep(thandiToken, pw);

  // ── Double-sealed record + session tag ──────────────────────────────────
  final Map<String, dynamic> escrow =
      ((await call('GET', '/v1/config')).body['escrow'])
          as Map<String, dynamic>;
  final Map<String, dynamic> cust = escrow['custodian'] as Map<String, dynamic>;
  final List<int> tag = List<int>.generate(16, (int i) => i * 7 % 256);
  Future<R> upload(String id, String token, List<int> t, String note) async {
    final List<int> inner = await SealedBox.seal(
      recipientPublicKey: base64.decode(cust['publicKey'] as String),
      plaintext: utf8.encode(
        jsonEncode(<String, Object?>{'note': note, 'events': <Object?>[]}),
      ),
      context: 'session-log-custodian:$id',
    );
    final List<int> outer = await SealedBox.seal(
      recipientPublicKey: base64.decode(escrow['publicKey'] as String),
      plaintext: inner,
      context: 'session-log:$id',
    );
    return call(
      'POST',
      '/v1/session-logs',
      token: token,
      body: <String, Object?>{
        'id': id,
        'sessionId': 'RIDGE9',
        'sessionName': 'Ridge walk',
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'sosCount': 1,
        'keyId': escrow['keyId'],
        'sealed': base64.encode(outer),
        'custodianKeyId': cust['keyId'],
        'sessionTag': base64.encode(t),
      },
    );
  }

  const String logId = '7d1e2f30-0000-4000-8000-0000000000a1';
  check(
    'double-sealed upload accepted',
    (await upload(logId, thandiToken, tag, 'SOS at the ridge')).status == 201,
  );
  final Device mPhone = await Device.create();
  final R malReg = await call(
    'POST',
    '/v1/auth/register',
    body: <String, Object?>{
      'email': 'mallory@example.org',
      'password': 'Sneaky lantern phrase 55',
      'displayName': 'Mallory',
    },
  );
  check('a second person (Mallory) can register', malReg.status == 202, malReg);
  await call(
    'POST',
    '/v1/auth/verify-email',
    body: <String, Object?>{
      'email': 'mallory@example.org',
      'code': await codeFor('mallory@example.org'),
      'password': 'Sneaky lantern phrase 55',
    },
  );
  final R mal = await login(
    'mallory@example.org',
    'Sneaky lantern phrase 55',
    mPhone,
  );
  check('Mallory signs in', mal.status == 200, mal);
  await upload(
    '7d1e2f30-0000-4000-8000-0000000000a2',
    mal.body['accessToken'] as String? ?? '',
    List<int>.filled(16, 1),
    'fake',
  );
  final R single = await call(
    'POST',
    '/v1/session-logs',
    token: thandiToken,
    body: <String, Object?>{
      'id': '7d1e2f30-0000-4000-8000-0000000000a3',
      'sessionId': 'RIDGE9',
      'sessionName': 'x',
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'keyId': escrow['keyId'],
      'sealed': base64.encode(
        await SealedBox.seal(
          recipientPublicKey: base64.decode(escrow['publicKey'] as String),
          plaintext: utf8.encode('{}'),
          context: 'session-log:7d1e2f30-0000-4000-8000-0000000000a3',
        ),
      ),
    },
  );
  check(
    'single-sealed upload refused (CUSTODIAN_REQUIRED)',
    single.error == 'custodian_required',
    single,
  );

  final R idx = await call(
    'GET',
    '/v1/admin/sessions?sessionId=RIDGE9',
    token: thandiToken,
  );
  check(
    'session index flags an upload from a non-member',
    (idx.body['sessions'] as List).single['unproven'] == true,
    idx,
  );
  final R detail = await call(
    'GET',
    '/v1/admin/sessions/RIDGE9',
    token: thandiToken,
  );
  final List<dynamic> logs = detail.body['logs'] as List<dynamic>;
  // Thandi's tag comes from the invite code, Mallory's does not. With one
  // upload each there is no majority: a tie proves nobody, and both records
  // are flagged for a responder to judge (see admin_service.session).
  check(
    'disagreeing tags with no majority: a tie, nobody proven, both flagged',
    logs.length == 2 &&
        logs.every(
          (dynamic l) => l['memberProven'] == null && l['tagsDisagree'] == true,
        ),
    logs,
  );
  check(
    'responder sees names, not email addresses',
    logs.every((dynamic l) => !(l as Map).containsKey('email')),
  );

  // ── Break-glass ─────────────────────────────────────────────────────────
  final R open = await call(
    'POST',
    '/v1/admin/session-logs/$logId/unseal',
    token: thandiToken,
    body: <String, Object?>{
      'reason': 'SOS raised on the ridge at 10:40',
      'caseRef': 'SAR-7',
    },
  );
  check(
    'unseal returns only the inner seal — the server cannot read it',
    open.status == 200 &&
        !open.body.containsKey('content') &&
        open.body['sealedInner'] != null,
    open,
  );
  final List<int> seed = base64Url.decode(
    base64Url.normalize(custodianPrivate.split(':').last),
  );
  final SimpleKeyPair custKp = await X25519().newKeyPairFromSeed(seed);
  final List<int> clear = await SealedBox.open(
    recipient: custKp,
    sealed: base64.decode(open.body['sealedInner'] as String),
    context: 'session-log-custodian:$logId',
  );
  check(
    'custodian key (held off-server) opens it',
    (jsonDecode(utf8.decode(clear)) as Map)['note'] == 'SOS at the ridge',
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final String log = File(logPath).readAsStringSync();
  check(
    'every admin emailed about the opening',
    log.contains('→ boss@example.org') &&
        log.contains('opened a session record') &&
        log.contains('SOS raised on the ridge at 10:40'),
  );

  // ── Audit ───────────────────────────────────────────────────────────────
  boss = await login(
    'boss@example.org',
    bossPw,
    bossPhone,
    totp: Totp.codeAt(_b32(bossSecret), Totp.stepAt(DateTime.now()) + 1),
  );
  if (boss.status == 200) bossToken = boss.body['accessToken'] as String;
  final R verify = await call(
    'GET',
    '/v1/admin/audit/verify',
    token: bossToken,
  );
  check(
    'audit chain verifies (keyed HMAC + backup anchor)',
    verify.body['ok'] == true,
    verify,
  );
  final R searched = await call(
    'GET',
    '/v1/admin/audit?action=session',
    token: bossToken,
  );
  final Set<String> actions = (searched.body['entries'] as List)
      .map((dynamic e) => e['action'] as String)
      .toSet();
  check(
    'session views and unseals are in the audit log',
    actions.containsAll(<String>{'session.viewed', 'session_log.unsealed'}),
    actions,
  );

  stdout.writeln('\n$passed passed, $failed failed');
  exit(failed == 0 ? 0 : 1);
}

List<int> _b32(String s) {
  const String a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final List<int> out = <int>[];
  int buf = 0, bits = 0;
  for (final int c in s.codeUnits) {
    buf = (buf << 5) | a.indexOf(String.fromCharCode(c));
    bits += 5;
    if (bits >= 8) {
      out.add((buf >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return out;
}
