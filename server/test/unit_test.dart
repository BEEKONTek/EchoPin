import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:echopin_server/echopin_server.dart';
import 'package:test/test.dart';

void main() {
  group('TOTP (RFC 6238)', () {
    final List<int> secret = utf8.encode('12345678901234567890');

    test('matches the RFC test vectors (last six digits)', () {
      // RFC 6238 Appendix B, SHA-1: 59 s → 94287082, 1111111109 s → 07081804.
      expect(Totp.codeAt(secret, 59 ~/ 30), '287082');
      expect(Totp.codeAt(secret, 1111111109 ~/ 30), '081804');
      expect(Totp.codeAt(secret, 2000000000 ~/ 30), '279037');
    });

    test('accepts one step of drift and refuses replays', () {
      final DateTime t = DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000, isUtc: true);
      final int step = Totp.stepAt(t);
      expect(Totp.verify(secret, Totp.codeAt(secret, step - 1), t), step - 1);
      expect(Totp.verify(secret, Totp.codeAt(secret, step - 2), t), isNull);
      expect(Totp.verify(secret, Totp.codeAt(secret, step), t, lastUsedStep: step), isNull);
      expect(Totp.verify(secret, 'abc123', t), isNull);
    });

    test('base32 matches the RFC 4648 alphabet', () {
      expect(Totp.base32(secret), 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
    });
  });

  group('passwords', () {
    test('hash and verify (fast params)', () async {
      const PasswordHasher h = PasswordHasher.fast();
      final String phc = await h.hash('correct horse battery');
      expect(phc, startsWith(r'$argon2id$v=19$m=256,t=1,p=1$'));
      expect(await h.verify('correct horse battery', phc), isTrue);
      expect(await h.verify('wrong horse battery', phc), isFalse);
      expect(await h.verify('x', 'not-a-hash'), isFalse);
    });

    test('policy explains what is wrong', () {
      expect(passwordProblem('short'), contains('at least'));
      expect(passwordProblem('aaaaaaaaaaaa'), contains('repetitive'));
      expect(passwordProblem('password1234'), contains('easy to guess'));
      expect(passwordProblem('thandi-rocks-99', email: 'thandi@example.com'), contains('email'));
      expect(passwordProblem('correct horse battery'), isNull);
    });
  });

  test('migration splitter keeps function bodies whole', () {
    final List<String> parts = splitStatements(r'''
-- a comment; with a semicolon
create table a (x int);
create function f() returns trigger language plpgsql as $$
begin
  raise exception 'no; really';
end $$;
create trigger t before update on a for each row execute function f();
''');
    expect(parts, hasLength(3));
    expect(parts[1], contains("raise exception 'no; really';"));
  });

  test('libpq target moves the password into the environment', () {
    final (String url, Map<String, String> env) =
        libpqTarget('postgresql://echopin:s3cr%3At@db:5432/echopin?sslmode=require');
    expect(url, 'postgresql://echopin@db:5432/echopin?sslmode=require');
    expect(env, <String, String>{'PGPASSWORD': 's3cr:t'});
  });

  group('backup format', () {
    final SecretKey key = SecretKey(List<int>.generate(32, (int i) => i));

    Future<Uint8List> encrypt(List<int> data) async {
      final Directory d = await Directory.systemTemp.createTemp('epbk');
      final File f = File('${d.path}/b');
      final IOSink s = f.openWrite();
      await BackupService.encryptStream(Stream<List<int>>.fromIterable(<List<int>>[data]), s, key);
      await s.close();
      final Uint8List bytes = await f.readAsBytes();
      await d.delete(recursive: true);
      return bytes;
    }

    Future<List<int>> decrypt(List<int> data, [SecretKey? k]) async {
      final Directory d = await Directory.systemTemp.createTemp('epbk');
      final File f = File('${d.path}/out');
      final IOSink s = f.openWrite();
      try {
        await BackupService.decryptStream(Stream<List<int>>.value(data), s, k ?? key);
      } finally {
        await s.close();
      }
      final List<int> out = await f.readAsBytes();
      await d.delete(recursive: true);
      return out;
    }

    test('round-trips across several frames', () async {
      final List<int> data = List<int>.generate(BackupService.frameSize * 2 + 1234, (int i) => i % 251);
      final Uint8List enc = await encrypt(data);
      expect(enc.sublist(0, 5), BackupService.magic);
      expect(await decrypt(enc), data);
    });

    test('round-trips an empty dump', () async {
      expect(await decrypt(await encrypt(<int>[])), isEmpty);
    });

    test('detects truncation, tampering and the wrong key', () async {
      final List<int> data = List<int>.generate(BackupService.frameSize + 10, (int i) => i % 7);
      final Uint8List enc = await encrypt(data);
      // Drop the final frame entirely: everything left still authenticates,
      // so only the missing final flag can catch it.
      final int firstFrameEnd = 5 + 1 + 4 + 12 + BackupService.frameSize + 16;
      await expectLater(decrypt(enc.sublist(0, firstFrameEnd)),
          throwsA(isA<BackupException>().having((BackupException e) => e.message, 'm', contains('truncated'))));
      final Uint8List flipped = Uint8List.fromList(enc)..[100] ^= 1;
      await expectLater(decrypt(flipped), throwsA(isA<BackupException>()));
      await expectLater(decrypt(enc, SecretKey(List<int>.filled(32, 9))), throwsA(isA<BackupException>()));
      await expectLater(decrypt(utf8.encode('PGDMP...')), throwsA(isA<BackupException>()));
    });
  });

  test('canonical JSON sorts keys recursively', () {
    expect(canonicalJson(<String, Object?>{'b': 1, 'a': <String, Object?>{'d': 2, 'c': 3}}),
        '{"a":{"c":3,"d":2},"b":1}');
  });
}
