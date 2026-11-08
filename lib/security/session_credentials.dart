import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:echo_pin/services/session_codec.dart';

/// Everything derived from a session code body.
///
/// HKDF-SHA256 (RFC 5869) separates the one secret into independent values:
///   - [sessionId]: public 8-character routing id, advertised over BLE and
///     mDNS so peers can find each other. One-way: it reveals nothing about
///     the code.
///   - the AEAD key that encrypts every message.
///   - [serverTag]: a 16-byte value every member computes identically and
///     includes with session records uploaded to a central server. It
///     proves the uploader held the invite code (the public session id
///     alone isn't enough to compute it), so the console can flag uploads
///     from outsiders. One-way: it reveals neither the code nor the key.
class SessionCredentials {
  SessionCredentials._(this.body, this.sessionId, this._key, this.serverTag);

  static const String _salt = 'echopin/v2/hkdf-salt';

  /// The secret code body (16 chars).
  final String body;

  /// Public routing id (8 chars from the code alphabet).
  final String sessionId;

  /// Membership tag for server uploads (see the class comment).
  final List<int> serverTag;

  SecretKeyData? _key;

  bool get isWiped => _key == null;

  SecretKey get key {
    final SecretKeyData? k = _key;
    if (k == null) throw StateError('Session credentials were wiped');
    return k;
  }

  static Future<SessionCredentials> derive(String body) async {
    if (!SessionCodec.isCanonicalBody(body)) {
      throw ArgumentError.value(body, 'body', 'not a session code body');
    }
    final SecretKey ikm = SecretKey(utf8.encode(body));
    final List<int> salt = utf8.encode(_salt);

    final List<int> idBytes = await _hkdf(ikm, salt, 'session-id', 8);
    final String sessionId = String.fromCharCodes(
      idBytes.map(
        (int b) =>
            SessionCodec.alphabet.codeUnitAt(b % SessionCodec.alphabet.length),
      ),
    );
    final List<int> keyBytes = await _hkdf(ikm, salt, 'aead-key', 32);
    final List<int> tag = await _hkdf(ikm, salt, 'server-member-tag', 16);
    return SessionCredentials._(
      body,
      sessionId,
      SecretKeyData(Uint8List.fromList(keyBytes)),
      tag,
    );
  }

  static Future<List<int>> _hkdf(
    SecretKey ikm,
    List<int> salt,
    String info,
    int length,
  ) async {
    final SecretKey out = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: length,
    ).deriveKey(secretKey: ikm, nonce: salt, info: utf8.encode(info));
    return out.extractBytes();
  }

  /// Best-effort zeroisation of the key on session exit.
  void wipe() {
    _key?.destroy();
    _key = null;
  }
}
