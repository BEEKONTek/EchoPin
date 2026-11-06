import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:echo_pin/services/session_codec.dart';

/// Peer id for a public key: 8 code-alphabet characters of SHA-256(key).
///
/// Ids are *derived* from keys, so a message's claimed sender is checked
/// against the key that signed it; the session additionally pins each id
/// to the first key seen (trust on first use) to defeat id collisions.
String peerIdForKey(List<int> publicKey) {
  final List<int> digest = crypto.sha256.convert(<int>[
    ...utf8.encode('echopin/v2/peer-id:'),
    ...publicKey,
  ]).bytes;
  return String.fromCharCodes(
    digest
        .take(8)
        .map(
          (int b) => SessionCodec.alphabet.codeUnitAt(
            b % SessionCodec.alphabet.length,
          ),
        ),
  );
}

/// 12-digit safety code people compare in person to verify each other.
/// Bound to the session, so it differs between sessions.
String safetyCodeFor(String sessionId, List<int> publicKey) {
  final List<int> digest = crypto.sha256.convert(<int>[
    ...utf8.encode('echopin/v2/safety:$sessionId:'),
    ...publicKey,
  ]).bytes;
  // 6 bytes = 48 bits; reduce to 12 decimal digits (~40 bits).
  int value = 0;
  for (int i = 0; i < 5; i++) {
    value = value * 256 + digest[i];
  }
  value = value * 256 + digest[5];
  final String digits = (value % 1000000000000).toString().padLeft(12, '0');
  return '${digits.substring(0, 4)} ${digits.substring(4, 8)} '
      '${digits.substring(8)}';
}

/// This device's identity for one session: a fresh Ed25519 key pair.
///
/// Ephemeral by design. A new key per session means members of two
/// different sessions cannot link this device across them.
class SessionIdentity {
  SessionIdentity._(this._keyPair, this.publicKey, this.peerId);

  static final Ed25519 _ed25519 = Ed25519();

  SimpleKeyPairData? _keyPair;
  final List<int> publicKey;
  final String peerId;

  static Future<SessionIdentity> generate() async {
    final SimpleKeyPair pair = await _ed25519.newKeyPair();
    final SimpleKeyPairData data = await pair.extract();
    final SimplePublicKey pub = await data.extractPublicKey();
    return SessionIdentity._(
      data,
      List<int>.unmodifiable(pub.bytes),
      peerIdForKey(pub.bytes),
    );
  }

  Future<List<int>> sign(List<int> message) async {
    final SimpleKeyPairData? pair = _keyPair;
    if (pair == null) throw StateError('Session identity was wiped');
    final Signature sig = await _ed25519.sign(message, keyPair: pair);
    return sig.bytes;
  }

  static Future<bool> verify(
    List<int> message,
    List<int> signature,
    List<int> publicKey,
  ) {
    return _ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  String safetyCode(String sessionId) => safetyCodeFor(sessionId, publicKey);

  void wipe() {
    _keyPair?.destroy();
    _keyPair = null;
  }
}
