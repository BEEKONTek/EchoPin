import 'dart:convert';

import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_kv_store.dart';

String _hex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('pbkdf2Sha256', () {
    // Published PBKDF2-HMAC-SHA256 vectors.
    test('password/salt c=1', () {
      expect(
        _hex(
          pbkdf2Sha256(
            password: utf8.encode('password'),
            salt: utf8.encode('salt'),
            iterations: 1,
          ),
        ),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('password/salt c=2', () {
      expect(
        _hex(
          pbkdf2Sha256(
            password: utf8.encode('password'),
            salt: utf8.encode('salt'),
            iterations: 2,
          ),
        ),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });

    test('RFC 7914 §11 passwd/salt c=1 dkLen=64 (multi-block)', () {
      expect(
        _hex(
          pbkdf2Sha256(
            password: utf8.encode('passwd'),
            salt: utf8.encode('salt'),
            iterations: 1,
            keyLength: 64,
          ),
        ),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc'
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
      );
    });
  });

  group('AdminAuthService', () {
    late MemoryKvStore kv;
    late DateTime now;

    AdminAuthService svc() => AdminAuthService(
      kv: kv,
      iterations: 10,
      maxAttempts: 3,
      lockoutDuration: const Duration(seconds: 30),
      useIsolate: false,
      clock: () => now,
    );

    setUp(() {
      kv = MemoryKvStore();
      now = DateTime(2026, 1, 1, 12);
    });

    test('validatePin enforces length and digits', () {
      expect(AdminAuthService.validatePin('123'), isNotNull);
      expect(AdminAuthService.validatePin('12a4'), isNotNull);
      expect(AdminAuthService.validatePin('1234567890123'), isNotNull);
      expect(AdminAuthService.validatePin('1234'), isNull);
    });

    test('verify without a PIN reports noPin', () async {
      expect((await svc().verify('1234')).status, AdminAuthStatus.noPin);
    });

    test('PIN is stored hashed, never in clear', () async {
      await svc().setPin('482916');
      expect(await svc().hasPin(), isTrue);
      final String joined = kv.data.values.join(' ');
      expect(joined.contains('482916'), isFalse);
      expect(joined.contains('pbkdf2-sha256'), isTrue);
    });

    test('correct PIN verifies; wrong PIN counts down', () async {
      await svc().setPin('1234');
      expect((await svc().verify('1234')).ok, isTrue);
      final AdminAuthResult r = await svc().verify('9999');
      expect(r.status, AdminAuthStatus.wrongPin);
      expect(r.attemptsRemaining, 2);
    });

    test('success resets the failure counter', () async {
      await svc().setPin('1234');
      await svc().verify('0000');
      await svc().verify('0000');
      expect((await svc().verify('1234')).ok, isTrue);
      expect((await svc().verify('0000')).attemptsRemaining, 2);
    });

    test(
      'locks out after maxAttempts, persists across instances, expires',
      () async {
        await svc().setPin('1234');
        await svc().verify('0000');
        await svc().verify('0000');
        final AdminAuthResult locked = await svc().verify('0000');
        expect(locked.status, AdminAuthStatus.lockedOut);

        // Even the right PIN is refused during lockout, from a new instance.
        expect((await svc().verify('1234')).status, AdminAuthStatus.lockedOut);
        expect(await svc().lockedUntil(), isNotNull);

        now = now.add(const Duration(seconds: 31));
        expect(await svc().lockedUntil(), isNull);
        expect((await svc().verify('1234')).ok, isTrue);
      },
    );

    test('changePin requires the current PIN', () async {
      await svc().setPin('1234');
      expect((await svc().changePin('0000', '5678')).ok, isFalse);
      expect((await svc().changePin('1234', '5678')).ok, isTrue);
      expect((await svc().verify('5678')).ok, isTrue);
      expect((await svc().verify('1234')).ok, isFalse);
    });

    test('changePin rejects an invalid new PIN', () async {
      await svc().setPin('1234');
      expect(() => svc().changePin('1234', '12'), throwsArgumentError);
    });

    test('clearPin removes PIN and lock state', () async {
      await svc().setPin('1234');
      await svc().verify('0000');
      await svc().clearPin();
      expect(await svc().hasPin(), isFalse);
      expect(kv.data, isEmpty);
    });

    test('corrupted stored hash never verifies', () async {
      await kv.write('echo_pin.admin_pin_v1', 'garbage');
      expect((await svc().verify('1234')).ok, isFalse);
    });
  });
}
