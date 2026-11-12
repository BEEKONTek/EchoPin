import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:echopin_protocol/echopin_protocol.dart';

/// Argon2id password hashing in PHC string format.
///
/// Parameters follow the OWASP minimum (19 MiB, 2 passes, 1 lane). Hashing
/// runs on a separate isolate so a burst of sign-ins never stalls the
/// event loop that serves everyone else.
class PasswordHasher {
  const PasswordHasher({
    this.memoryKib = 19456,
    this.iterations = 2,
    this.parallelism = 1,
  });

  /// Cheap parameters for tests only.
  const PasswordHasher.fast()
    : memoryKib = 256,
      iterations = 1,
      parallelism = 1;

  final int memoryKib;
  final int iterations;
  final int parallelism;

  Future<String> hash(String password) async {
    final Random r = Random.secure();
    final List<int> salt = List<int>.generate(16, (_) => r.nextInt(256));
    final List<int> digest = await _derive(
      password,
      salt,
      memoryKib,
      iterations,
      parallelism,
    );
    return '\$argon2id\$v=19\$m=$memoryKib,t=$iterations,p=$parallelism'
        '\$${_b64(salt)}\$${_b64(digest)}';
  }

  /// Constant-time check. Unknown formats are simply false.
  Future<bool> verify(String password, String phc) async {
    final List<String> parts = phc.split('\$');
    // ['', 'argon2id', 'v=19', 'm=..,t=..,p=..', salt, hash]
    if (parts.length != 6 || parts[1] != 'argon2id') return false;
    final Map<String, int> params = <String, int>{};
    for (final String kv in parts[3].split(',')) {
      final List<String> p = kv.split('=');
      if (p.length != 2) return false;
      final int? v = int.tryParse(p[1]);
      if (v == null) return false;
      params[p[0]] = v;
    }
    final int? m = params['m'], t = params['t'], p = params['p'];
    if (m == null || t == null || p == null) return false;
    final List<int> salt = _unb64(parts[4]);
    final List<int> expected = _unb64(parts[5]);
    final List<int> actual = await _derive(password, salt, m, t, p);
    return constantTimeEquals(actual, expected);
  }

  /// Burns the same time as a real verification, for unknown emails, so
  /// response timing does not reveal which addresses have accounts.
  Future<void> dummyVerify(String password) async {
    await _derive(
      password,
      List<int>.filled(16, 0),
      memoryKib,
      iterations,
      parallelism,
    );
  }

  static Future<List<int>> _derive(
    String password,
    List<int> salt,
    int m,
    int t,
    int p,
  ) {
    return Isolate.run(() async {
      final Argon2id a = Argon2id(
        memory: m,
        iterations: t,
        parallelism: p,
        hashLength: 32,
      );
      final SecretKey k = await a.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      return k.extractBytes();
    });
  }

  static String _b64(List<int> b) => base64.encode(b).replaceAll('=', '');

  static List<int> _unb64(String s) =>
      base64.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));
}

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Returns a human sentence describing what is wrong, or null if the
/// password is acceptable.
String? passwordProblem(String password, {String? email}) {
  if (password.length < ProtocolLimits.minPasswordLength) {
    return 'Use at least ${ProtocolLimits.minPasswordLength} characters';
  }
  if (password.length > ProtocolLimits.maxPasswordLength) {
    return 'Use at most ${ProtocolLimits.maxPasswordLength} characters';
  }
  if (password.split('').toSet().length < 4) {
    return 'That password is too repetitive';
  }
  final String lower = password.toLowerCase();
  if (_common.any(lower.contains) && lower.length < 16) {
    return 'That password is too easy to guess';
  }
  if (email != null) {
    final String local = email.split('@').first.toLowerCase();
    if (local.length >= 4 && lower.contains(local)) {
      return 'Do not use your email address in your password';
    }
  }
  return null;
}

const List<String> _common = <String>[
  'password',
  '123456',
  'qwerty',
  'letmein',
  'welcome',
  'iloveyou',
  'admin',
  'abc123',
  'monkey',
  'dragon',
  'echopin',
  '111111',
  'passw0rd',
];
