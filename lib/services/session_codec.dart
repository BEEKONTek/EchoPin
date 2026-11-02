import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

/// Encodes/decodes session ids as human-friendly codes with a checksum.
///
/// Format: `ECHO-XXXX-XXXX-YY`
///   - `XXXXXXXX` is the raw session id (8 chars from [_alphabet]).
///   - `YY` is a truncated HMAC-SHA256 checksum for typo detection.
///
/// The [secret] is the HMAC key. Default is a dev value; a follow-up batch
/// will inject a per-install secret from secure storage.
class SessionCodec {
  SessionCodec({this.secret = 'echo_pin-dev-v1'});

  static const String _prefix = 'ECHO';
  static const String _alphabet = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';

  final String secret;

  /// Generates a fresh 8-character session id.
  String generateId() {
    final math.Random rng = math.Random.secure();
    final List<int> chars = List<int>.generate(
      8,
      (_) => _alphabet.codeUnitAt(rng.nextInt(_alphabet.length)),
    );
    return String.fromCharCodes(chars);
  }

  /// Formats [id] as a displayable code with checksum.
  String encode(String id) {
    final String clean = id.toUpperCase();
    if (clean.length != 8) {
      throw ArgumentError.value(id, 'id', 'must be exactly 8 characters');
    }
    final String checksum = _checksum(clean);
    return '$_prefix-${clean.substring(0, 4)}-'
        '${clean.substring(4, 8)}-$checksum';
  }

  /// Parses a user-entered code.
  ///
  /// When [lenient] is true (default), inputs that don't look like an ECHO
  /// code are accepted verbatim. ECHO codes always have their checksum
  /// verified regardless of [lenient].
  String? parse(String code, {bool lenient = true}) {
    final String trimmed = code.trim();
    if (trimmed.isEmpty) return null;

    final String normalized = trimmed
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (!normalized.startsWith(_prefix)) {
      return lenient ? trimmed : null;
    }
    final String body = normalized.substring(_prefix.length);
    if (body.length < 3) return null;
    final String id = body.substring(0, body.length - 2);
    final String checksum = body.substring(body.length - 2);
    if (_checksum(id) != checksum) return null;
    return id;
  }

  String _checksum(String id) {
    final Hmac mac = Hmac(sha256, utf8.encode(secret));
    final Digest digest = mac.convert(utf8.encode(id));
    final List<int> bytes = digest.bytes;
    final String a = _alphabet[bytes[0] % _alphabet.length];
    final String b = _alphabet[bytes[1] % _alphabet.length];
    return '$a$b';
  }
}
