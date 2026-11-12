import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// RFC 6238 time-based one-time passwords (HMAC-SHA1, 30 s, 6 digits),
/// compatible with every common authenticator app.
abstract final class Totp {
  static const int stepSeconds = 30;
  static const int digits = 6;

  static List<int> newSecret() {
    final Random r = Random.secure();
    return List<int>.generate(20, (_) => r.nextInt(256));
  }

  static int stepAt(DateTime t) =>
      t.toUtc().millisecondsSinceEpoch ~/ 1000 ~/ stepSeconds;

  static String codeAt(List<int> secret, int step) {
    final ByteData counter = ByteData(8)..setUint64(0, step);
    final List<int> mac = Hmac(
      sha1,
      secret,
    ).convert(counter.buffer.asUint8List()).bytes;
    final int offset = mac.last & 0x0f;
    final int binary =
        ((mac[offset] & 0x7f) << 24) |
        (mac[offset + 1] << 16) |
        (mac[offset + 2] << 8) |
        mac[offset + 3];
    return (binary % 1000000).toString().padLeft(digits, '0');
  }

  /// Returns the matched step, or null. Accepts one step of clock drift
  /// either way, and refuses any step at or before [lastUsedStep] so a
  /// code cannot be replayed.
  static int? verify(
    List<int> secret,
    String code,
    DateTime now, {
    int? lastUsedStep,
  }) {
    final String clean = code.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^\d{6}$').hasMatch(clean)) return null;
    final int current = stepAt(now);
    for (final int step in <int>[current, current - 1, current + 1]) {
      if (lastUsedStep != null && step <= lastUsedStep) continue;
      if (codeAt(secret, step) == clean) return step;
    }
    return null;
  }

  static String otpauthUri({
    required List<int> secret,
    required String account,
    String issuer = 'EchoPin',
  }) {
    final String label = Uri.encodeComponent('$issuer:$account');
    return 'otpauth://totp/$label?secret=${base32(secret)}'
        '&issuer=${Uri.encodeComponent(issuer)}&digits=$digits&period=$stepSeconds';
  }

  static const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static String base32(List<int> data) {
    final StringBuffer out = StringBuffer();
    int buffer = 0, bits = 0;
    for (final int b in data) {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5) {
        out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
    return out.toString();
  }
}
