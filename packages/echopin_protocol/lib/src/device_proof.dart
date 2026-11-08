import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Proof that a request comes from the device that registered a key.
///
/// Each install keeps an Ed25519 key pair in the OS keystore. Signing in
/// registers its public key; refreshing tokens requires a fresh signature.
/// A copied refresh token is therefore useless without the device, which
/// is what a hardware identifier such as an IMEI can never offer: an IMEI
/// is a number anyone can read and replay, a private key is not.
abstract final class DeviceProof {
  /// How far a proof's timestamp may drift from the server clock.
  static const Duration maxSkew = Duration(minutes: 5);

  static final Ed25519 _ed25519 = Ed25519();

  /// Canonical bytes to sign. [purpose] separates login proofs from refresh
  /// proofs so one can never be replayed as the other; [subject] binds the
  /// proof to the email or token it accompanies.
  static List<int> message({
    required String purpose,
    required String subject,
    required int timestampMs,
  }) => utf8.encode('echopin/v1/device-proof|$purpose|$subject|$timestampMs');

  static Future<List<int>> sign({
    required SimpleKeyPair deviceKey,
    required String purpose,
    required String subject,
    required int timestampMs,
  }) async {
    final Signature sig = await _ed25519.sign(
      message(purpose: purpose, subject: subject, timestampMs: timestampMs),
      keyPair: deviceKey,
    );
    return sig.bytes;
  }

  /// True only for a valid signature by [publicKey] whose timestamp is
  /// within [maxSkew] of [now].
  static Future<bool> verify({
    required List<int> publicKey,
    required List<int> signature,
    required String purpose,
    required String subject,
    required int timestampMs,
    required DateTime now,
  }) async {
    if (publicKey.length != 32 || signature.length != 64) return false;
    final int skew = (now.millisecondsSinceEpoch - timestampMs).abs();
    if (skew > maxSkew.inMilliseconds) return false;
    try {
      return await _ed25519.verify(
        message(purpose: purpose, subject: subject, timestampMs: timestampMs),
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
