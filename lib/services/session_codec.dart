import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:flutter/foundation.dart';

/// A parsed, checksum-verified invitation to a session.
@immutable
class SessionInvite {
  const SessionInvite({required this.body, this.sessionName});

  /// The 16-character secret. Everything else (public session id,
  /// encryption key) is derived from it; see `SessionCredentials`.
  final String body;

  /// Optional human name carried by QR / link invites.
  final String? sessionName;

  @override
  bool operator ==(Object other) =>
      other is SessionInvite &&
      other.body == body &&
      other.sessionName == sessionName;

  @override
  int get hashCode => Object.hash(body, sessionName);
}

/// Session codes, version 2.
///
/// Format: `ECHO-XXXX-XXXX-XXXX-XXXX-CC`
///   - `X…` (16 chars) is the session secret: ~78 bits from a 30-character
///     alphabet without look-alikes (no 0/O, 1/I/L, U).
///   - `CC` is a keyless checksum so a typo is caught on *any* device. It is
///     integrity for humans, not authentication: possession of the code is
///     what grants membership, and the code is what keys the encryption.
///
/// QR codes and links carry the same code as
/// `echopin://join?c=ECHO-…&n=<session name>`.
class SessionCodec {
  SessionCodec({math.Random? random})
    : _random = random ?? math.Random.secure();

  static const String prefix = 'ECHO';
  static const String alphabet = 'ABCDEFGHJKMNPQRSTVWXYZ23456789';
  static const int bodyLength = 16;
  static const int checkLength = 2;
  static const String linkScheme = 'echopin';

  final math.Random _random;

  /// True when [body] is exactly a 16-character code body.
  static bool isCanonicalBody(String body) =>
      body.length == bodyLength && body.split('').every(alphabet.contains);

  /// Generates a fresh, uniformly random session secret.
  String generateBody() {
    return String.fromCharCodes(
      List<int>.generate(
        bodyLength,
        (_) => alphabet.codeUnitAt(_random.nextInt(alphabet.length)),
      ),
    );
  }

  /// `ECHO-XXXX-XXXX-XXXX-XXXX-CC` for [body].
  String encode(String body) {
    if (!isCanonicalBody(body)) {
      throw ArgumentError.value(body, 'body', 'not a 16-character code body');
    }
    final List<String> groups = <String>[
      for (int i = 0; i < bodyLength; i += 4) body.substring(i, i + 4),
    ];
    return '$prefix-${groups.join('-')}-${checksum(body)}';
  }

  /// Link / QR payload for [body].
  String encodeLink(String body, {String? sessionName}) {
    return Uri(
      scheme: linkScheme,
      host: 'join',
      queryParameters: <String, String>{
        'c': encode(body),
        if (sessionName != null && sessionName.trim().isNotEmpty)
          'n': sessionName.trim(),
      },
    ).toString();
  }

  /// Parses typed codes, bare bodies, and `echopin://join` links.
  ///
  /// Throws [InvalidCodeError] describing exactly what is wrong.
  SessionInvite parse(String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) throw const InvalidCodeError(CodeProblem.empty);

    String raw = trimmed;
    String? name;
    if (trimmed.contains('://') ||
        trimmed.toLowerCase().startsWith('echopin:')) {
      final Uri? uri = Uri.tryParse(trimmed);
      if (uri == null || uri.scheme.toLowerCase() != linkScheme) {
        throw const InvalidCodeError(CodeProblem.notEchoPin);
      }
      final String? c = uri.queryParameters['c'];
      if (c == null || c.isEmpty) {
        throw const InvalidCodeError(CodeProblem.notEchoPin);
      }
      final String? v = uri.queryParameters['v'];
      if (v != null && v != '2') {
        throw const InvalidCodeError(CodeProblem.unsupportedVersion);
      }
      raw = c;
      final String? n = uri.queryParameters['n'];
      name = (n == null || n.trim().isEmpty) ? null : _cleanName(n);
    }

    String normalized = raw.toUpperCase().replaceAll(RegExp(r'[\s\-_.·]'), '');
    final bool prefixed = normalized.startsWith(prefix);
    if (prefixed) normalized = normalized.substring(prefix.length);

    const int expected = bodyLength + checkLength;
    if (!prefixed && normalized.length != expected) {
      throw const InvalidCodeError(CodeProblem.notEchoPin);
    }
    if (!RegExp(r'^[A-Z0-9]*$').hasMatch(normalized)) {
      throw const InvalidCodeError(CodeProblem.notEchoPin);
    }

    final List<String> bad = <String>{
      for (final String ch in normalized.split(''))
        if (!alphabet.contains(ch)) ch,
    }.toList()..sort();
    if (bad.isNotEmpty) {
      throw InvalidCodeError(
        CodeProblem.invalidCharacters,
        detail: bad.join(', '),
      );
    }
    if (normalized.length != expected) {
      throw InvalidCodeError(
        CodeProblem.wrongLength,
        detail: '${normalized.length}',
      );
    }

    final String body = normalized.substring(0, bodyLength);
    final String check = normalized.substring(bodyLength);
    if (checksum(body) != check) {
      throw const InvalidCodeError(CodeProblem.checksumMismatch);
    }
    return SessionInvite(body: body, sessionName: name);
  }

  /// Keyless 2-character checksum. Detects ~99.9% of typos.
  static String checksum(String body) {
    final List<int> digest = sha256
        .convert(utf8.encode('echopin/v2/check:$body'))
        .bytes;
    return '${alphabet[digest[0] % alphabet.length]}'
        '${alphabet[digest[1] % alphabet.length]}';
  }

  static String _cleanName(String n) {
    final String collapsed = n.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length > 40 ? collapsed.substring(0, 40) : collapsed;
  }
}
