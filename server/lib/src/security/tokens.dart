import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Opaque bearer tokens. Only SHA-256 hashes are stored, so a database leak
/// does not hand out working tokens.
abstract final class Tokens {
  static String random([int bytes = 32]) {
    final Random r = Random.secure();
    return base64Url
        .encode(List<int>.generate(bytes, (_) => r.nextInt(256)))
        .replaceAll('=', '');
  }

  static Uint8List hash(String token) =>
      Uint8List.fromList(sha256.convert(utf8.encode(token)).bytes);

  /// Eight random digits for email verification and password reset.
  ///
  /// Eight, not six: with 5 guesses per code and at most 10 codes a day,
  /// an attacker gets ~18,000 guesses a year against 100 million
  /// possibilities (0.02 %), versus 1.8 % for six digits.
  static String emailCode() =>
      Random.secure().nextInt(100000000).toString().padLeft(8, '0');

  static Uint8List codeHash(String accountId, String purpose, String code) =>
      Uint8List.fromList(
        sha256.convert(utf8.encode('echopin/v1/code|$accountId|$purpose|$code')).bytes,
      );
}
