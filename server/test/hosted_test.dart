import 'dart:convert';
import 'dart:io';

import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:echopin_server/echopin_server.dart';
import 'package:echopin_server/src/backup/backup_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'fake_supabase_storage.dart';

void main() {
  group('ECHOPIN_KEYS bundle', () {
    test('round-trips, and rotation keeps old escrow keys', () async {
      final String bundle = await ServerKeys.newBundle();
      final ServerKeys k1 = await ServerKeys.fromBundle(bundle);
      final ServerKeys k2 = await ServerKeys.fromBundle(ServerKeys.rotateBundle(bundle));
      expect(k2.escrowKeys.keys, contains(k1.currentEscrowId), reason: 'old records still open');
      expect(k2.currentEscrowId, isNot(k1.currentEscrowId));
      expect(await k2.backupKey.extractBytes(), await k1.backupKey.extractBytes());
    });

    test('a keys directory converts to the same keys', () async {
      final Directory d = await Directory.systemTemp.createTemp('keys');
      await ServerKeys.create('${d.path}/k');
      final ServerKeys fromDir = await ServerKeys.load('${d.path}/k');
      final ServerKeys fromEnv = await ServerKeys.fromBundle(ServerKeys.bundleFromDir('${d.path}/k'));
      expect(fromEnv.currentEscrowId, fromDir.currentEscrowId);
      expect(await fromEnv.dataKey.extractBytes(), await fromDir.dataKey.extractBytes());
      await d.delete(recursive: true);
    });

    test('common copy-paste slips still load the same keys', () async {
      final String bundle = await ServerKeys.newBundle();
      final List<int> want = await (await ServerKeys.fromBundle(bundle)).dataKey.extractBytes();
      final String wrapped = [
        for (int i = 0; i < bundle.length; i += 60) bundle.substring(i, (i + 60).clamp(0, bundle.length))
      ].join('\n');
      for (final String pasted in <String>[
        'ECHOPIN_KEYS=$bundle',
        'export ECHOPIN_KEYS="$bundle"',
        "'$bundle'",
        '  $wrapped\n',
        bundle.replaceAll('=', ''),
      ]) {
        final ServerKeys k = await ServerKeys.fromBundle(pasted);
        expect(await k.dataKey.extractBytes(), want, reason: pasted.substring(0, 20));
      }
    });

    test('a truncated bundle is refused without echoing it', () async {
      final String bundle = await ServerKeys.newBundle();
      final String cut = bundle.substring(0, 80);
      await expectLater(
        ServerKeys.fromBundle(cut),
        throwsA(isA<KeysException>()
            .having((KeysException e) => e.message, 'm', contains('cut off'))
            .having((KeysException e) => e.message, 'm', isNot(contains(cut.substring(0, 20))))),
      );
    });

    test('garbage is refused with instructions', () async {
      await expectLater(ServerKeys.fromBundle('not-a-bundle'),
          throwsA(isA<KeysException>().having((KeysException e) => e.message, 'm', contains('init-keys --print-env'))));
    });

    test('with no keys configured a hosted server refuses to invent them', () async {
      await expectLater(
        loadServerKeys(const ServerConfig(databaseUrl: 'postgresql://x@h/db'), freshDatabase: true),
        throwsA(isA<KeysException>().having((KeysException e) => e.message, 'm', contains('ECHOPIN_KEYS'))),
      );
      final ServerKeys k = await loadServerKeys(
        ServerConfig(databaseUrl: 'postgresql://x@h/db', keysBundle: await ServerKeys.newBundle()),
        freshDatabase: false,
      );
      expect(k.escrowKeys, hasLength(1));
    });
  });

  group('configuration', () {
    test('TLS is required for hosted databases, off for local ones', () {
      String q(String url, String k) => Uri.parse(Db.withDefaults(url)).queryParameters[k]!;
      expect(q('postgresql://u@localhost:5432/db', 'sslmode'), 'disable');
      expect(q('postgresql://u@db:5432/db', 'sslmode'), 'disable');
      expect(q('postgresql://postgres.abc:pw@aws-0-eu-central-1.pooler.supabase.com:5432/postgres', 'sslmode'), 'require');
      expect(q('postgresql://u@remote.example/db?sslmode=verify-full', 'sslmode'), 'verify-full');
      expect(q('postgresql://u@localhost/db', 'max_connection_count'), '5');
    });

    test('hosted settings are read and checked', () {
      final ServerConfig c = ServerConfig.fromEnvironment(<String, String>{
        'DATABASE_URL': 'postgresql://u@h/db',
        'ECHOPIN_KEYS': 'abc',
        'MAIL_PROVIDER': 'brevo',
        'BREVO_API_KEY': 'xkeysib-1',
        'MAIL_FROM': 'alerts@example.org',
        'BACKUP_STORE': 'supabase',
        'SUPABASE_URL': 'https://abc.supabase.co',
        'SUPABASE_SERVICE_KEY': 'sb_secret_x',
        'DATABASE_POOL_SIZE': '4',
      });
      expect(c.keysBundle, 'abc');
      expect(c.keysDir, isNull);
      expect(c.mail.provider, MailProvider.brevo);
      expect(c.backupStore.kind, BackupStoreKind.supabase);
      expect(c.databasePoolSize, 4);

      expect(
        () => ServerConfig.fromEnvironment(<String, String>{'DATABASE_URL': 'x', 'MAIL_PROVIDER': 'brevo'}),
        throwsA(isA<ConfigException>().having((ConfigException e) => e.message, 'm', contains('BREVO_API_KEY'))),
      );
      expect(
        () => ServerConfig.fromEnvironment(<String, String>{'DATABASE_URL': 'x', 'BACKUP_STORE': 'supabase'}),
        throwsA(isA<ConfigException>().having((ConfigException e) => e.message, 'm', contains('SUPABASE_URL'))),
      );
      expect(
        () => ServerConfig.fromEnvironment(<String, String>{'DATABASE_URL': 'x', 'MAIL_PROVIDER': 'pigeon'}),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('HTTP mail', () {
    test('Brevo and Resend get the right request; refusals throw', () async {
      final List<http.Request> seen = <http.Request>[];
      int status = 201;
      final http.Client client = MockClient((http.Request r) async {
        seen.add(r);
        return http.Response('{}', status);
      });
      const OutgoingMail mail = OutgoingMail(to: 'ana@example.com', subject: 'Code 123456', text: 'Your code is 123456');

      await HttpMailer(const MailConfig(provider: MailProvider.brevo, apiKey: 'bk', from: 'alerts@example.org'), client: client)
          .send(mail);
      expect(seen.last.url.toString(), 'https://api.brevo.com/v3/smtp/email');
      expect(seen.last.headers['api-key'], 'bk');
      final Map<String, dynamic> b = jsonDecode(seen.last.body) as Map<String, dynamic>;
      expect(b['to'], <Object?>[<String, Object?>{'email': 'ana@example.com'}]);
      expect(b['textContent'], contains('123456'));

      status = 200;
      await HttpMailer(const MailConfig(provider: MailProvider.resend, apiKey: 'rk', from: 'a@echo.org'), client: client)
          .send(mail);
      expect(seen.last.url.toString(), 'https://api.resend.com/emails');
      expect(seen.last.headers['authorization'], 'Bearer rk');
      expect((jsonDecode(seen.last.body) as Map<String, dynamic>)['from'], 'EchoPin <a@echo.org>');

      status = 401;
      await expectLater(
        HttpMailer(const MailConfig(provider: MailProvider.brevo, apiKey: 'bad', from: 'a@b.co'), client: client).send(mail),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Supabase backup store', () {
    test('splits into parts under the size limit, joins them back, deletes them', () async {
      final FakeSupabaseStorage fake = FakeSupabaseStorage(key: 'sb_secret_test', maxObjectBytes: 100);
      final SupabaseBackupStore store = SupabaseBackupStore(
        url: 'https://abc.supabase.co/', key: 'sb_secret_test', bucket: 'echopin-backups',
        client: fake.client, partSize: 100,
      );
      await store.ensureReady();
      await store.ensureReady(); // already exists: fine
      final Directory d = await Directory.systemTemp.createTemp('store');
      final File src = File('${d.path}/b.epbk')..writeAsBytesSync(List<int>.generate(350, (int i) => i % 256));
      await store.put('echopin-x.epbk', src);
      expect(fake.objects.keys.where((String k) => k.startsWith('echopin-backups/echopin-x.epbk/')), hasLength(4));

      final File out = File('${d.path}/out');
      await store.fetch('echopin-x.epbk', out);
      expect(out.readAsBytesSync(), src.readAsBytesSync());

      await store.delete('echopin-x.epbk');
      expect(fake.objects, isEmpty);
      await expectLater(store.fetch('echopin-x.epbk', out), throwsA(isA<StoreException>()));
      expect(store.existsCheap('anything'), isNull);
      await d.delete(recursive: true);
    });

    test('new secret keys travel only as apikey; legacy JWT keys also as Bearer', () async {
      final FakeSupabaseStorage newKey = FakeSupabaseStorage(key: 'sb_secret_abc');
      await SupabaseBackupStore(url: 'https://x.supabase.co', key: 'sb_secret_abc', bucket: 'b', client: newKey.client)
          .ensureReady();
      expect(newKey.requests.single.headers.containsKey('authorization'), isFalse);

      final FakeSupabaseStorage jwt = FakeSupabaseStorage(key: 'eyJhbGciOi.x.y');
      await SupabaseBackupStore(url: 'https://x.supabase.co', key: 'eyJhbGciOi.x.y', bucket: 'b', client: jwt.client)
          .ensureReady();
      expect(jwt.requests.single.headers['authorization'], 'Bearer eyJhbGciOi.x.y');
    });
  });

  test('restore list keeps everything except the public schema itself', () {
    const String toc = '''
;
; Archive created at 2026-11-07
4; 2615 2200 SCHEMA - public pg_database_owner
3487; 0 0 COMMENT - SCHEMA public pg_database_owner
222; 1255 17964 FUNCTION public audit_log_immutable() echopin
221; 1259 17961 TABLE public accounts echopin
3480; 0 17961 TABLE DATA public accounts echopin''';
    final String kept = BackupService.restoreList(toc);
    expect(kept, isNot(contains('SCHEMA - public')));
    expect(kept, isNot(contains('COMMENT - SCHEMA public')));
    expect(kept, contains('TABLE public accounts'));
    expect(kept, contains('FUNCTION public audit_log_immutable'));
  });

  group('hardening (unit)', () {
    test('staff roles need two-step before the console answers', () {
      AuthContext ctx({required AccountRole role, required bool twoStep}) => AuthContext(
        accountId: 'a', email: 'a@b.co', displayName: 'A', role: role, deviceId: 'd',
        authSessionId: 's', ip: '1.1.1.1', twoStep: twoStep, staffTwoStepRequired: true);
      expect(() => ctx(role: AccountRole.admin, twoStep: false).require(AccountRole.responder),
          throwsA(isA<ApiException>().having((ApiException e) => e.code, 'code', 'two_step_required')));
      ctx(role: AccountRole.admin, twoStep: true).require(AccountRole.admin);
      expect(() => ctx(role: AccountRole.member, twoStep: true).require(AccountRole.responder),
          throwsA(isA<ApiException>().having((ApiException e) => e.code, 'code', 'forbidden')));
    });

    test('breach check sends only a 5-character prefix and fails open', () async {
      // SHA-1("password") = 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8
      final List<Uri> asked = <Uri>[];
      final HibpBreachChecker hibp = HibpBreachChecker(client: MockClient((http.Request r) async {
        asked.add(r.url);
        expect(r.headers['Add-Padding'], 'true');
        return http.Response('1E4C9B93F3F0682250B6CF8331B7EE68FD8:9545824\r\n0000000000000000000000000000000000A:0', 200);
      }));
      expect(await hibp.timesBreached('password'), 9545824);
      expect(asked.single.path, '/range/5BAA6');
      expect(await hibp.timesBreached('a long unusual phrase nobody uses'), 0);

      final HibpBreachChecker down = HibpBreachChecker(client: MockClient((_) async => throw Exception('offline')));
      expect(await down.timesBreached('password'), 0, reason: 'fail open: sign-up keeps working');
    });

    test('dangerous settings are refused outside local development', () {
      expect(
        () => ServerConfig.fromEnvironment(<String, String>{
          'DATABASE_URL': 'postgresql://u@aws-0-eu-central-1.pooler.supabase.com/postgres', 'ECHOPIN_DEV': 'true'}),
        throwsA(isA<ConfigException>().having((ConfigException e) => e.message, 'm', contains('local development'))),
      );
      expect(
        () => ServerConfig.fromEnvironment(<String, String>{'DATABASE_URL': 'postgresql://u@h/db', 'CORS_ORIGINS': '*'}),
        throwsA(isA<ConfigException>()),
      );
      final ServerConfig local = ServerConfig.fromEnvironment(<String, String>{
        'DATABASE_URL': 'postgresql://u@localhost/db', 'ECHOPIN_DEV': '1', 'CORS_ORIGINS': '*'});
      expect(local.devMode, isTrue);
      final ServerConfig defaults = ServerConfig.fromEnvironment(<String, String>{'DATABASE_URL': 'postgresql://u@h/db'});
      expect(defaults.requireStaffTwoStep, isTrue);
      expect(defaults.passwordBreachCheck, isTrue);
      expect(defaults.unsealAlerts, isTrue);
      expect(defaults.custodianRequired, isFalse);
      expect(
        () => ServerConfig.fromEnvironment(<String, String>{'DATABASE_URL': 'postgresql://u@h/db', 'CUSTODIAN_PUBLIC_KEYS': 'nope'}),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
