import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory stand-in for the EchoPin server, speaking the real wire
/// format. It verifies device proofs with the shared protocol code and can
/// open sealed logs with its escrow key, so tests prove the app's crypto
/// matches what the real server expects.
class FakeEchoPinServer {
  FakeEchoPinServer._(this.escrow, this.escrowPublic);

  static Future<FakeEchoPinServer> start() async {
    final SimpleKeyPair kp = await X25519().newKeyPair();
    return FakeEchoPinServer._(kp, (await kp.extractPublicKey()).bytes);
  }

  final SimpleKeyPair escrow;
  final List<int> escrowPublic;

  String password = 'correct horse battery';
  String role = 'member';
  bool totpRequired = false;
  String totpCode = '123456';
  bool offline = false;

  /// Next upload gets this status (then clears).
  int? failNextUploadWith;
  String? refreshRefusal;
  final Set<String> revokedDeviceKeys = <String>{};

  int refreshCount = 0;
  int loginCount = 0;
  final List<String> loginKeys = <String>[];
  final Map<String, List<int>> _deviceKeys = <String, List<int>>{};
  final Set<String> _validAccess = <String>{};
  final Map<String, String> _refreshToDevice = <String, String>{};
  int _seq = 0;

  final List<Map<String, dynamic>> sessionLogs = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> diagnostics = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> reports = <Map<String, dynamic>>[];

  String get escrowKeyId => SealedBox.keyIdFor(escrowPublic);

  /// When set, /v1/config offers this custodian key (second seal).
  SimpleKeyPair? custodian;
  List<int>? custodianPublic;
  Future<void> enableCustodian() async {
    custodian = await X25519().newKeyPair();
    custodianPublic = (await custodian!.extractPublicKey()).bytes;
  }

  /// Last device registration seen at login.
  Map<String, dynamic>? lastDevice;

  /// Opens an uploaded sealed log the way break-glass plus a responder's
  /// console would: outer layer with the escrow key, inner with the
  /// custodian key when the log is double-sealed.
  Future<Map<String, dynamic>> open(Map<String, dynamic> log) async {
    List<int> clear = await SealedBox.open(
      recipient: escrow,
      sealed: base64.decode(log['sealed'] as String),
      context: 'session-log:${log['id']}',
    );
    if (log['custodianKeyId'] != null) {
      clear = await SealedBox.open(
        recipient: custodian!,
        sealed: clear,
        context: 'session-log-custodian:${log['id']}',
      );
    }
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  /// Invalidates every access token, as expiry would.
  void expireAccessTokens() => _validAccess.clear();

  /// How far this fake server's clock is ahead of the device's. Every
  /// response carries a `Date` header from this clock, like a real server.
  Duration serverSkew = Duration.zero;
  DateTime get _now => DateTime.now().toUtc().add(serverSkew);

  http.Client get client => MockClient((http.Request req) async {
    final http.Response r = await _handle(req);
    return http.Response(r.body, r.statusCode,
        headers: <String, String>{...r.headers, 'date': HttpDate.format(_now)});
  });

  Future<http.Response> _handle(http.Request req) async {
    if (offline) throw http.ClientException('offline', req.url);
    final String path = req.url.path;
    final Map<String, dynamic> body =
        req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
    switch ((req.method, path)) {
      case ('GET', '/v1/config'):
        return _json(<String, Object?>{
          'escrow': <String, Object?>{
            'keyId': escrowKeyId,
            'publicKey': base64.encode(escrowPublic),
            if (custodianPublic != null)
              'custodian': <String, Object?>{
                'keyId': SealedBox.keyIdFor(custodianPublic!),
                'publicKey': base64.encode(custodianPublic!),
              },
          },
        });
      case ('POST', '/v1/auth/login'):
        return _login(body);
      case ('POST', '/v1/auth/refresh'):
        return _refresh(body);
      case ('POST', '/v1/auth/logout'):
        return _json(<String, Object?>{'status': 'signed_out'});
      case ('POST', '/v1/auth/register'):
        return _json(<String, Object?>{'status': 'verification_sent'}, 202);
    }
    if (!_validAccess.contains(req.headers['authorization']?.replaceFirst('Bearer ', ''))) {
      return _error(401, 'unauthorized', 'Sign in again to continue');
    }
    switch ((req.method, path)) {
      case ('GET', '/v1/me'):
        return _json(_account());
      case ('GET', '/v1/me/devices'):
        return _json(<String, Object?>{
          'devices': <Object?>[
            <String, Object?>{
              'id': 'device-1', 'label': 'Android device', 'platform': 'Android',
              'appVersion': '0.4.0', 'lastSeenAt': DateTime.now().toUtc().toIso8601String(),
              'revokedAt': null, 'current': true,
            },
          ],
        });
      case ('GET', '/v1/me/reports'):
        return _json(<String, Object?>{'reports': <Object?>[]});
      case ('GET', '/v1/admin/overview'):
        if (role == 'member') return _error(403, 'forbidden', 'Your account is not allowed to do that');
        final DateTime now = DateTime.now().toUtc();
        return _json(<String, Object?>{
          'generatedAt': now.toIso8601String(),
          'accounts': <String, Object?>{'active': 12, 'pending': 1, 'disabled': 0},
          'devicesActive24h': 9,
          'diagnostics24h': <String, Object?>{'errors': 2, 'warnings': 3},
          'reports': <String, Object?>{'open': 4, 'critical': 1},
          'sessions': <String, Object?>{'last24h': 3, 'last7d': 11, 'withSos7d': 1},
          'versions': <Object?>[
            <String, Object?>{'platform': 'Android', 'appVersion': '0.4.0', 'devices': 7},
          ],
          'daily': <Object?>[
            for (int i = 13; i >= 0; i--)
              <String, Object?>{
                'day': now.subtract(Duration(days: i)).toIso8601String(),
                'sessions': i % 3, 'sos': i == 2 ? 1 : 0, 'errors': i % 2, 'reports': i == 0 ? 1 : 0,
              },
          ],
          'lastBackup': <String, Object?>{
            'status': 'ok', 'fileName': 'echopin-x.epbk', 'sizeBytes': 1000,
            'startedAt': now.subtract(const Duration(hours: 3)).toIso8601String(),
          },
        });
      case ('POST', '/v1/session-logs'):
      case ('POST', '/v1/diagnostics'):
      case ('POST', '/v1/reports'):
        final int? fail = failNextUploadWith;
        if (fail != null) {
          failNextUploadWith = null;
          return _error(fail, fail >= 500 ? 'server_error' : 'invalid_input', 'Refused ($fail)');
        }
        if (path == '/v1/session-logs') {
          if (body.containsKey('plain')) return _error(400, 'invalid_input', 'sent unsealed!');
          SealedBox.checkStructure(base64.decode(body['sealed'] as String));
          sessionLogs.add(body);
        } else if (path == '/v1/diagnostics') {
          diagnostics.add(body);
        } else {
          reports.add(body);
        }
        return _json(<String, Object?>{'status': 'stored'}, 201);
    }
    return _error(404, 'not_found', 'That endpoint was not found');
  }

  Future<http.Response> _login(Map<String, dynamic> b) async {
    loginCount++;
    if (b['password'] != password) {
      return _error(401, 'invalid_credentials', 'That email and password do not match');
    }
    final Map<String, dynamic> device = b['device'] as Map<String, dynamic>;
    lastDevice = device;
    final List<int> pub = base64.decode(device['publicKey'] as String);
    loginKeys.add(device['publicKey'] as String);
    final bool ok = await DeviceProof.verify(
      publicKey: pub,
      signature: base64.decode(b['proofSignature'] as String),
      purpose: 'login',
      subject: (b['email'] as String).toLowerCase(),
      timestampMs: b['proofTimestamp'] as int,
      now: _now,
    );
    if (!ok) return _error(400, 'device_proof_invalid', 'bad proof');
    if (revokedDeviceKeys.contains(device['publicKey'])) {
      return _error(403, 'device_revoked', 'This device was removed');
    }
    if (totpRequired && b['totp'] != totpCode) {
      return b['totp'] == null
          ? _error(401, 'totp_required', 'Enter the 6-digit code from your authenticator app')
          : _error(401, 'totp_invalid', 'That authenticator code is not right');
    }
    final String deviceId = 'device-${_deviceKeys.length + 1}';
    _deviceKeys[deviceId] = pub;
    return _json(<String, Object?>{..._tokens(deviceId), 'account': _account()});
  }

  Future<http.Response> _refresh(Map<String, dynamic> b) async {
    refreshCount++;
    final String token = b['refreshToken'] as String;
    final String? deviceId = _refreshToDevice[token];
    if (refreshRefusal != null) {
      _refreshToDevice.remove(token);
      return _error(401, refreshRefusal!, 'For your safety this device was signed out. Sign in again');
    }
    if (deviceId == null || deviceId != b['deviceId']) {
      return _error(401, 'session_revoked', 'Sign in again to continue');
    }
    final bool ok = await DeviceProof.verify(
      publicKey: _deviceKeys[deviceId]!,
      signature: base64.decode(b['proofSignature'] as String),
      purpose: 'refresh',
      subject: base64Url.encode(crypto.sha256.convert(utf8.encode(token)).bytes),
      timestampMs: b['proofTimestamp'] as int,
      now: _now,
    );
    // Like the real server: a bad proof is refused before the token is
    // used, so the token stays valid.
    if (!ok) return _error(401, 'device_proof_invalid', 'bad proof');
    _refreshToDevice.remove(token);
    return _json(_tokens(deviceId));
  }

  Map<String, Object?> _tokens(String deviceId) {
    final String access = 'access-${++_seq}';
    final String refresh = 'refresh-$_seq';
    _validAccess.add(access);
    _refreshToDevice[refresh] = deviceId;
    final DateTime now = DateTime.now().toUtc();
    return <String, Object?>{
      'accessToken': access,
      'refreshToken': refresh,
      'accessExpiresAt': now.add(const Duration(minutes: 30)).toIso8601String(),
      'refreshExpiresAt': now.add(const Duration(days: 30)).toIso8601String(),
      'deviceId': deviceId,
    };
  }

  Map<String, Object?> _account() => <String, Object?>{
    'id': 'acct-1',
    'email': 'ana@example.com',
    'displayName': 'Ana',
    'role': role,
    'status': 'active',
    'totpEnabled': totpRequired,
  };

  static http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: <String, String>{'content-type': 'application/json'},
  );

  static http.Response _error(int status, String code, String message) =>
      _json(<String, Object?>{'error': code, 'message': message}, status);
}
