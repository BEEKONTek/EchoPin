// ACCOUNT MODELS: plain data the app keeps about the signed-in account.
//
// Account (who you are and your console role), AuthTokens (short-lived
// access token plus refresh token, with their expiry times) and EscrowKey
// (the server's public key that session logs are sealed to; its id is
// checked against the key bytes so a garbled key is never used).

import 'dart:convert';

import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/foundation.dart';

@immutable
class Account {
  const Account({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
    this.totpEnabled = false,
  });

  final String id;
  final String email;
  final String displayName;
  final AccountRole role;
  final bool totpEnabled;

  /// Responders and admins get the central console.
  bool get canUseConsole => role.atLeast(AccountRole.responder);
  bool get isAdmin => role == AccountRole.admin;

  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: j['id'] as String,
    email: j['email'] as String,
    displayName: j['displayName'] as String? ?? '',
    role: AccountRole.fromWire(j['role']) ?? AccountRole.member,
    totpEnabled: j['totpEnabled'] == true,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'email': email,
    'displayName': displayName,
    'role': role.wire,
    'totpEnabled': totpEnabled,
  };
}

@immutable
class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
    required this.deviceId,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final String deviceId;

  /// Refresh a minute early so a request never races the expiry.
  bool accessUsableAt(DateTime now) =>
      accessExpiresAt.isAfter(now.add(const Duration(minutes: 1)));

  factory AuthTokens.fromJson(Map<String, dynamic> j) => AuthTokens(
    accessToken: j['accessToken'] as String,
    refreshToken: j['refreshToken'] as String,
    accessExpiresAt: DateTime.parse(j['accessExpiresAt'] as String).toUtc(),
    refreshExpiresAt: DateTime.parse(j['refreshExpiresAt'] as String).toUtc(),
    deviceId: j['deviceId'] as String,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'accessExpiresAt': accessExpiresAt.toIso8601String(),
    'refreshExpiresAt': refreshExpiresAt.toIso8601String(),
    'deviceId': deviceId,
  };
}

/// The server's escrow public key, cached so logs can be sealed offline,
/// plus the optional custodian key for a second, inner seal.
///
/// With a custodian key, records are sealed twice: inside to the
/// custodian (whose private half only responders' devices hold), outside
/// to the server. The server alone then can't read them.
@immutable
class EscrowKey {
  const EscrowKey({
    required this.keyId,
    required this.publicKey,
    this.custodianKeyId,
    this.custodianPublicKey,
  });

  final String keyId;
  final List<int> publicKey;
  final String? custodianKeyId;
  final List<int>? custodianPublicKey;

  bool get doubleSeal => custodianPublicKey != null;

  factory EscrowKey.fromJson(Map<String, dynamic> j) {
    final List<int> pub = base64.decode(j['publicKey'] as String);
    final String id = j['keyId'] as String;
    // Never trust a key whose id does not match its bytes.
    if (pub.length != 32 || SealedBox.keyIdFor(pub) != id) {
      throw const FormatException('Escrow key does not match its id');
    }
    final Object? c = j['custodian'];
    if (c is Map<String, dynamic>) {
      final List<int> cpub = base64.decode(c['publicKey'] as String);
      final String cid = c['keyId'] as String;
      if (cpub.length != 32 || SealedBox.keyIdFor(cpub) != cid) {
        throw const FormatException('Custodian key does not match its id');
      }
      return EscrowKey(keyId: id, publicKey: pub, custodianKeyId: cid, custodianPublicKey: cpub);
    }
    return EscrowKey(keyId: id, publicKey: pub);
  }

  /// This key with a different (or pinned) custodian.
  EscrowKey withCustodian(List<int>? custodian) => EscrowKey(
    keyId: keyId,
    publicKey: publicKey,
    custodianKeyId: custodian == null ? null : SealedBox.keyIdFor(custodian),
    custodianPublicKey: custodian,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'keyId': keyId,
    'publicKey': base64.encode(publicKey),
    if (custodianPublicKey != null)
      'custodian': <String, Object?>{
        'keyId': custodianKeyId,
        'publicKey': base64.encode(custodianPublicKey!),
      },
  };
}
