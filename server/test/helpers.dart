import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:echopin_server/echopin_server.dart';
import 'package:shelf/shelf.dart';

/// Admin URL of a Postgres the tests may create databases on, e.g.
/// `postgresql://echopin@127.0.0.1:54329/postgres`. Integration tests skip
/// when it is unset; `tool/test.sh` starts a throwaway cluster and sets it.
final Random _rng = Random();

final String? testAdminUrl = Platform.environment['ECHOPIN_TEST_DATABASE_URL'];

String? get skipWithoutDb => testAdminUrl == null
    ? 'Set ECHOPIN_TEST_DATABASE_URL (or run tool/test.sh) for integration tests'
    : null;

/// A controllable clock.
class TestClock {
  DateTime now = DateTime.now().toUtc();
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

/// One isolated database, key set and server per test file.
class TestEnv {
  TestEnv._(
    this.dbName,
    this.url,
    this.db,
    this.keysDir,
    this.backupsDir,
    this.server,
    this.mailer,
    this.clock,
    this.custodian,
  );

  /// The custodian key pair this server accepts (private half = what a
  /// responder's console would hold).
  final SimpleKeyPair custodian;

  final String dbName;
  final String url;
  final Db db;
  final Directory keysDir;
  final Directory backupsDir;
  final EchoPinServer server;
  final MemoryMailer mailer;
  final TestClock clock;

  static Future<TestEnv> create() async {
    final String admin = testAdminUrl!;
    final String name =
        'echopin_test_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final Db adminDb = Db.connect(admin);
    await adminDb.execute('create database $name');
    await adminDb.close();
    final String url = Uri.parse(admin).replace(path: '/$name').toString();
    final Db db = Db.connect(url);
    await migrate(db);
    final Directory tmp = await Directory.systemTemp.createTemp(
      'echopin-test-',
    );
    final Directory keysDir = Directory('${tmp.path}/keys');
    final Directory backupsDir = Directory('${tmp.path}/backups');
    await ServerKeys.create(keysDir.path);
    final ServerKeys keys = await ServerKeys.load(keysDir.path);
    final MemoryMailer mailer = MemoryMailer();
    final TestClock clock = TestClock();
    final SimpleKeyPair custodian = await X25519().newKeyPair();
    final List<String> custodianPublicKeys = <String>[
      base64.encode((await custodian.extractPublicKey()).bytes),
    ];
    final ServerConfig config = ServerConfig(
      databaseUrl: url,
      keysDir: keysDir.path,
      backupsDir: backupsDir.path,
      backupsEnabled: false,
      trustProxy: true,
      // Console tests use responders without authenticators; the policy
      // itself is tested in unit_test.dart.
      requireStaffTwoStep: false,
      passwordBreachCheck: false,
      custodianPublicKeys: custodianPublicKeys,
      // CI pins these to the service's PostgreSQL major; locally the
      // defaults on PATH are used.
      pgDump: Platform.environment['PG_DUMP'] ?? 'pg_dump',
      pgRestore: Platform.environment['PG_RESTORE'] ?? 'pg_restore',
    );
    final EchoPinServer server = EchoPinServer.create(
      config: config,
      db: db,
      keys: keys,
      mailer: mailer,
      hasher: const PasswordHasher.fast(),
      // Deterministic tests: wait for mail, no timing padding.
      mailInBackground: false,
      minPublicResponse: Duration.zero,
      clock: clock.call,
    );
    return TestEnv._(
      name,
      url,
      db,
      keysDir,
      backupsDir,
      server,
      mailer,
      clock,
      custodian,
    );
  }

  Future<void> dispose() async {
    await db.close();
    final Db adminDb = Db.connect(testAdminUrl!);
    await adminDb.execute('drop database if exists $dbName with (force)');
    await adminDb.close();
    try {
      keysDir.parent.deleteSync(recursive: true);
    } catch (_) {}
  }

  Future<ApiResult> call(
    String method,
    String path, {
    Object? body,
    String? token,
    String? ip,
  }) async {
    // A fresh address per call keeps per-IP rate limits out of the way of
    // tests that are about something else.
    ip ??= '10.${_rng.nextInt(255)}.${_rng.nextInt(255)}.${_rng.nextInt(255)}';
    final Response res = await server.handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: <String, String>{
          'content-type': 'application/json',
          if (token != null) 'authorization': 'Bearer $token',
          'x-forwarded-for': ip,
        },
      ),
    );
    final String text = await res.readAsString();
    return ApiResult(res.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  /// Registers, verifies and returns a signed-in user.
  Future<TestUser> signUp(
    String email, {
    String password = 'correct horse battery',
    String name = 'Test',
  }) async {
    final ApiResult r = await call(
      'POST',
      '/v1/auth/register',
      body: <String, Object?>{
        'email': email,
        'password': password,
        'displayName': name,
      },
    );
    if (r.status != 202) throw StateError('register: ${r.body}');
    final String code = mailer.lastCodeFor(email)!;
    final ApiResult v = await call(
      'POST',
      '/v1/auth/verify-email',
      body: <String, Object?>{
        'email': email,
        'code': code,
        'password': password,
      },
    );
    if (v.status != 200) throw StateError('verify: ${v.body}');
    final TestDevice device = await TestDevice.create();
    final ApiResult l = await login(email, password, device);
    if (l.status != 200) throw StateError('login: ${l.body}');
    return TestUser(email, password, device, l.map);
  }

  Future<ApiResult> login(
    String email,
    String password,
    TestDevice device, {
    String? totp,
  }) async {
    final int ts = clock.now.millisecondsSinceEpoch;
    return call(
      'POST',
      '/v1/auth/login',
      body: <String, Object?>{
        'email': email,
        'password': password,
        'totp': ?totp,
        'device': <String, Object?>{
          'publicKey': base64.encode(device.publicKey),
          'label': 'Test phone',
          'platform': 'Android',
          'appVersion': '0.4.0',
        },
        'proofTimestamp': ts,
        'proofSignature': base64.encode(
          await device.sign('login', email.toLowerCase(), ts),
        ),
      },
    );
  }

  Future<ApiResult> refresh(
    TestUser u, {
    String? refreshToken,
    TestDevice? device,
  }) async {
    final String token = refreshToken ?? u.refreshToken;
    final int ts = clock.now.millisecondsSinceEpoch;
    final TestDevice d = device ?? u.device;
    return call(
      'POST',
      '/v1/auth/refresh',
      body: <String, Object?>{
        'refreshToken': token,
        'deviceId': u.deviceId,
        'proofTimestamp': ts,
        'proofSignature': base64.encode(
          await d.sign('refresh', AuthService.refreshSubject(token), ts),
        ),
      },
    );
  }

  Future<void> setRole(String email, AccountRole role) => db.execute(
    'update accounts set role = @r where email_normalized = @e',
    <String, Object?>{'r': role.wire, 'e': email.toLowerCase()},
  );
}

class ApiResult {
  ApiResult(this.status, this.body);
  final int status;
  final Object? body;
  Map<String, dynamic> get map => body as Map<String, dynamic>;
  String? get error => body is Map ? (body as Map)['error'] as String? : null;
  @override
  String toString() => '$status $body';
}

class TestDevice {
  TestDevice(this.keyPair, this.publicKey);
  final SimpleKeyPair keyPair;
  final List<int> publicKey;

  static Future<TestDevice> create() async {
    final SimpleKeyPair kp = await Ed25519().newKeyPair();
    return TestDevice(kp, (await kp.extractPublicKey()).bytes);
  }

  Future<List<int>> sign(String purpose, String subject, int ts) =>
      DeviceProof.sign(
        deviceKey: keyPair,
        purpose: purpose,
        subject: subject,
        timestampMs: ts,
      );
}

class TestUser {
  TestUser(this.email, this.password, this.device, Map<String, dynamic> login)
    : accessToken = login['accessToken'] as String,
      refreshToken = login['refreshToken'] as String,
      deviceId = login['deviceId'] as String,
      accountId = (login['account'] as Map<String, dynamic>)['id'] as String;

  final String email;
  final String password;
  final TestDevice device;
  String accessToken;
  String refreshToken;
  final String deviceId;
  final String accountId;

  void take(Map<String, dynamic> tokens) {
    accessToken = tokens['accessToken'] as String;
    refreshToken = tokens['refreshToken'] as String;
  }
}
