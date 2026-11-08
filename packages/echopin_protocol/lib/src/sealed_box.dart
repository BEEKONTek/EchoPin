import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Thrown when a sealed box is malformed, was sealed to a different key,
/// was bound to a different context, or has been tampered with.
class SealedBoxException implements Exception {
  const SealedBoxException(this.message);
  final String message;
  @override
  String toString() => 'SealedBoxException: $message';
}

/// Anonymous public-key encryption to an escrow key ("sealed box").
///
/// A device seals a record to the server's escrow public key. Afterwards
/// nobody can read it, the device included, until someone holding the
/// escrow private key opens it. EchoPin's server only does that through
/// its audited break-glass endpoint.
///
/// Layout (all lengths in bytes):
///
///     version(1) | ephemeralPublicKey(32) | nonce(24) | ciphertext | mac(16)
///
/// - Key agreement: X25519(ephemeral, recipient).
/// - KDF: HKDF-SHA256, salt = ephemeralPublic ‖ recipientPublic,
///   info = "echopin/v1/seal".
/// - AEAD: XChaCha20-Poly1305. The associated data is the recipient key id
///   plus a caller-supplied [context] (for example `session-log:<uuid>`), so
///   a sealed blob cannot be moved onto a different record without failing
///   to open.
class SealedBox {
  SealedBox._();

  static const int version = 1;
  static const int _headerLength = 1 + 32 + 24;
  static const int _macLength = 16;
  static const int minLength = _headerLength + _macLength;

  static final X25519 _x25519 = X25519();
  static final Xchacha20 _aead = Xchacha20.poly1305Aead();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Stable 16-hex-character identifier for an escrow public key. Sent with
  /// every sealed record so the server can pick the right private key after
  /// a rotation.
  static String keyIdFor(List<int> publicKey) {
    final List<int> digest = crypto.sha256.convert(<int>[
      ...utf8.encode('echopin/v1/escrow-key:'),
      ...publicKey,
    ]).bytes;
    return _hex(digest.sublist(0, 8));
  }

  static Future<Uint8List> seal({
    required List<int> recipientPublicKey,
    required List<int> plaintext,
    required String context,
  }) async {
    if (recipientPublicKey.length != 32) {
      throw const SealedBoxException('Escrow key must be 32 bytes');
    }
    final SimpleKeyPair ephemeral = await _x25519.newKeyPair();
    final SimplePublicKey ephemeralPublic = await ephemeral.extractPublicKey();
    final SecretKey key = await _deriveKey(
      keyPair: ephemeral,
      remotePublic: recipientPublicKey,
      ephemeralPublic: ephemeralPublic.bytes,
      recipientPublic: recipientPublicKey,
    );
    final List<int> nonce = _aead.newNonce();
    final SecretBox box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: _aad(recipientPublicKey, context),
    );
    final BytesBuilder out = BytesBuilder(copy: false)
      ..addByte(version)
      ..add(ephemeralPublic.bytes)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.takeBytes();
  }

  static Future<Uint8List> open({
    required SimpleKeyPair recipient,
    required List<int> sealed,
    required String context,
  }) async {
    checkStructure(sealed);
    final SimplePublicKey recipientPublic = await recipient.extractPublicKey();
    final List<int> ephemeralPublic = sealed.sublist(1, 33);
    final List<int> nonce = sealed.sublist(33, _headerLength);
    final List<int> cipherText = sealed.sublist(
      _headerLength,
      sealed.length - _macLength,
    );
    final List<int> mac = sealed.sublist(sealed.length - _macLength);

    final SecretKey key = await _deriveKey(
      keyPair: recipient,
      remotePublic: ephemeralPublic,
      ephemeralPublic: ephemeralPublic,
      recipientPublic: recipientPublic.bytes,
    );
    try {
      final List<int> clear = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _aad(recipientPublic.bytes, context),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const SealedBoxException(
        'Wrong key, wrong context, or the data was altered',
      );
    }
  }

  /// Cheap shape check that needs no key, for the server's ingest path.
  static void checkStructure(List<int> sealed) {
    if (sealed.length < minLength) {
      throw const SealedBoxException('Too short to be a sealed box');
    }
    if (sealed[0] != version) {
      throw SealedBoxException('Unsupported sealed box version ${sealed[0]}');
    }
  }

  /// Both sides reach the same X25519 secret from opposite halves; the
  /// salt is always ephemeral ‖ recipient so the derived key matches.
  static Future<SecretKey> _deriveKey({
    required SimpleKeyPair keyPair,
    required List<int> remotePublic,
    required List<int> ephemeralPublic,
    required List<int> recipientPublic,
  }) async {
    final SecretKey shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(remotePublic, type: KeyPairType.x25519),
    );
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: <int>[...ephemeralPublic, ...recipientPublic],
      info: utf8.encode('echopin/v1/seal'),
    );
  }

  static List<int> _aad(List<int> recipientPublic, String context) =>
      utf8.encode('echopin/v1/seal|${keyIdFor(recipientPublic)}|$context');

  static String _hex(List<int> bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}
