import 'dart:convert';

import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../admin_service.dart';
import '../auth/auth_service.dart';
import '../backup/backup_service.dart';
import '../db/database.dart';
import '../security/custodian.dart';
import '../security/keys.dart';
import '../telemetry_service.dart';
import 'http.dart';

const String serverVersion = '1.1.0';

/// Every HTTP endpoint, versioned under `/v1`.
Router buildRouter({
  required Db db,
  required ServerKeys keys,
  required AuthService auth,
  required TelemetryService telemetry,
  required AdminService admin,
  required BackupService backups,
  required ClientIpPolicy ipPolicy,
  CustodianKeys? custodian,
}) {
  final Router r = Router(
    notFoundHandler: (Request req) {
      throw ApiException.notFound('That endpoint');
    },
  );

  String ip(Request req) => clientIp(req, policy: ipPolicy);
  Future<AuthContext> who(Request req) =>
      auth.authenticate(req.headers['authorization'], ip(req));
  // Query-string access: see http.dart. Sizes are clamped, cursors bounded,
  // free text length-capped, so no caller can ask for "everything".
  String? qStr(Request req, String k) =>
      queryStr(req, k, max: ProtocolLimits.maxSearchQuery);
  int qLimit(Request req, int fallback) => queryInt(
    req,
    'limit',
    fallback: fallback,
    min: 1,
    max: ProtocolLimits.maxPageSize,
  );
  int qOffset(Request req) =>
      queryInt(req, 'offset', fallback: 0, max: 1 << 31);
  int? qBefore(Request req) => queryIntOrNull(req, 'before');

  // ── Public ─────────────────────────────────────────────────────────────

  r.get('/v1/health', (Request req) async {
    bool dbOk = true;
    try {
      await db.one('select 1 as ok');
    } catch (_) {
      dbOk = false;
    }
    return json(<String, Object?>{
      'ok': dbOk,
      'version': serverVersion,
      'database': dbOk ? 'up' : 'down',
    }, status: dbOk ? 200 : 503);
  });

  /// What an app needs before it can seal anything. Cached on the device so
  /// sealing keeps working offline.
  r.get('/v1/config', (Request req) async {
    return json(<String, Object?>{
      'escrow': <String, Object?>{
        'keyId': keys.currentEscrowId,
        'publicKey': _b64(keys.currentEscrowPublicKey),
        if (custodian != null && custodian.configured)
          'custodian': <String, Object?>{
            'keyId': custodian.currentId,
            'publicKey': _b64(custodian.publicKeys[custodian.currentId]!),
          },
      },
      'limits': <String, Object?>{
        'minPasswordLength': ProtocolLimits.minPasswordLength,
        'maxReportBody': ProtocolLimits.maxReportBody,
      },
      'serverVersion': serverVersion,
    });
  });

  // ── Auth ───────────────────────────────────────────────────────────────

  r.post('/v1/auth/register', (Request req) async {
    final Map<String, dynamic> b = await readJson(req);
    await auth.register(
      email: b.str('email', max: 254),
      password: b.str('password', max: 256, trim: false),
      displayName: b.str('displayName', max: 80),
      ip: ip(req),
    );
    return json(const <String, Object?>{
      'status': 'verification_sent',
      'message': 'Check your email for an 8-digit code',
    }, status: 202);
  });

  r.post('/v1/auth/verify-email', (Request req) async {
    final Map<String, dynamic> b = await readJson(req);
    await auth.verifyEmail(
      email: b.str('email', max: 254),
      code: b.str('code', max: 12),
      password: b.str('password', max: 256, trim: false),
      ip: ip(req),
    );
    return json(const <String, Object?>{'status': 'verified'});
  });

  r.post('/v1/auth/resend-code', (Request req) async {
    final Map<String, dynamic> b = await readJson(req);
    await auth.resendVerification(email: b.str('email', max: 254), ip: ip(req));
    return json(const <String, Object?>{
      'status': 'sent_if_pending',
    }, status: 202);
  });

  r.post('/v1/auth/login', (Request req) async {
    final Map<String, dynamic> b = await readJson(req);
    final Object? dev = b['device'];
    if (dev is! Map<String, dynamic>) {
      throw ApiException.badRequest('device is required');
    }
    final (IssuedTokens tokens, Map<String, Object?> account) = await auth
        .login(
          email: b.str('email', max: 254),
          password: b.str('password', max: 256, trim: false),
          totpCode: b.optStr('totp', max: 12),
          device: DeviceRegistration(
            publicKey: dev.b64('publicKey', length: 32),
            label: dev.str('label', max: 80),
            platform: dev.str('platform', max: 40),
            appVersion: dev.optStr('appVersion', max: 40),
            // Missing means an older app: assume the keystore was used.
            secureStorage: dev['secureStorage'] != false,
          ),
          proofTimestampMs: b.integer('proofTimestamp', max: 1 << 52),
          proofSignature: b.b64('proofSignature', length: 64),
          ip: ip(req),
        );
    return json(<String, Object?>{...tokens.toJson(), 'account': account});
  });

  r.post('/v1/auth/refresh', (Request req) async {
    final Map<String, dynamic> b = await readJson(req);
    final IssuedTokens t = await auth.refresh(
      refreshToken: b.str('refreshToken', max: 200),
      deviceId: b.str('deviceId', max: 36),
      proofTimestampMs: b.integer('proofTimestamp', max: 1 << 52),
      proofSignature: b.b64('proofSignature', length: 64),
      ip: ip(req),
    );
    return json(t.toJson());
  });

  r.post('/v1/auth/logout', (Request req) async {
    await auth.logout(await who(req));
    return json(const <String, Object?>{'status': 'signed_out'});
  });

  r.post('/v1/auth/password/forgot', (Request req) async {
    final Map<String, dynamic> b = await readJson(req);
    await auth.forgotPassword(email: b.str('email', max: 254), ip: ip(req));
    return json(const <String, Object?>{
      'status': 'sent_if_registered',
    }, status: 202);
  });

  r.post('/v1/auth/password/reset', (Request req) async {
    final Map<String, dynamic> b = await readJson(req);
    await auth.resetPassword(
      email: b.str('email', max: 254),
      code: b.str('code', max: 12),
      newPassword: b.str('newPassword', max: 256, trim: false),
      ip: ip(req),
    );
    return json(const <String, Object?>{'status': 'password_reset'});
  });

  // ── Me ─────────────────────────────────────────────────────────────────

  r.get('/v1/me', (Request req) async {
    final AuthContext ctx = await who(req);
    return json(await auth.accountJson(ctx.accountId));
  });

  r.patch('/v1/me', (Request req) async {
    final AuthContext ctx = await who(req);
    final Map<String, dynamic> b = await readJson(req);
    await auth.updateProfile(ctx, displayName: b.str('displayName', max: 80));
    return json(await auth.accountJson(ctx.accountId));
  });

  r.post('/v1/me/password', (Request req) async {
    final AuthContext ctx = await who(req);
    final Map<String, dynamic> b = await readJson(req);
    await auth.changePassword(
      ctx,
      current: b.str('currentPassword', max: 256, trim: false),
      next: b.str('newPassword', max: 256, trim: false),
    );
    return json(const <String, Object?>{'status': 'password_changed'});
  });

  r.post('/v1/me/totp/setup', (Request req) async {
    return json(await auth.totpSetup(await who(req)));
  });

  r.post('/v1/me/totp/enable', (Request req) async {
    final AuthContext ctx = await who(req);
    final Map<String, dynamic> b = await readJson(req);
    await auth.totpEnable(
      ctx,
      b.str('code', max: 12),
      password: b.str('password', max: 256, trim: false),
    );
    return json(const <String, Object?>{'status': 'totp_enabled'});
  });

  r.post('/v1/me/totp/disable', (Request req) async {
    final AuthContext ctx = await who(req);
    final Map<String, dynamic> b = await readJson(req);
    await auth.totpDisable(
      ctx,
      password: b.str('password', max: 256, trim: false),
      code: b.str('code', max: 12),
    );
    return json(const <String, Object?>{'status': 'totp_disabled'});
  });

  r.get('/v1/me/devices', (Request req) async {
    final AuthContext ctx = await who(req);
    final List<Map<String, Object?>> list = await auth.devices(ctx.accountId);
    return json(<String, Object?>{
      'devices': list
          .map(
            (Map<String, Object?> d) => <String, Object?>{
              ...d,
              'current': d['id'] == ctx.deviceId,
            },
          )
          .toList(),
    });
  });

  r.delete('/v1/me/devices/<id>', (Request req, String id) async {
    final AuthContext ctx = await who(req);
    await auth.revokeDevice(
      ctx.accountId,
      uuidParam(id, what: 'That device'),
      ctx.actor,
    );
    return json(const <String, Object?>{'status': 'revoked'});
  });

  r.get('/v1/me/reports', (Request req) async {
    return json(<String, Object?>{
      'reports': await telemetry.myReports(await who(req)),
    });
  });

  // ── Telemetry ──────────────────────────────────────────────────────────

  r.post('/v1/diagnostics', (Request req) async {
    final AuthContext ctx = await who(req);
    await telemetry.addDiagnostics(ctx, await readJson(req));
    return json(const <String, Object?>{'status': 'stored'}, status: 201);
  });

  r.post('/v1/session-logs', (Request req) async {
    final AuthContext ctx = await who(req);
    final Map<String, dynamic> b = await readJson(
      req,
      limit: ProtocolLimits.maxSealedLogBytes * 2,
    );
    final bool created = await telemetry.addSessionLog(ctx, b);
    return json(<String, Object?>{
      'status': created ? 'stored' : 'duplicate',
    }, status: created ? 201 : 200);
  });

  r.post('/v1/reports', (Request req) async {
    final AuthContext ctx = await who(req);
    final Map<String, dynamic> body = await readJson(req);
    return json(await telemetry.addReport(ctx, body), status: 201);
  });

  // ── Admin ──────────────────────────────────────────────────────────────

  r.get('/v1/admin/overview', (Request req) async {
    return json(await admin.overview(await who(req)));
  });

  r.get('/v1/admin/accounts', (Request req) async {
    final AuthContext ctx = await who(req);
    return json(<String, Object?>{
      'accounts': await admin.accounts(
        ctx,
        query: qStr(req, 'q'),
        role: qStr(req, 'role'),
        status: qStr(req, 'status'),
        limit: qLimit(req, 50),
        offset: qOffset(req),
      ),
    });
  });

  r.get('/v1/admin/accounts/<id>', (Request req, String id) async {
    return json(
      await admin.account(await who(req), uuidParam(id, what: 'That account')),
    );
  });

  r.patch('/v1/admin/accounts/<id>', (Request req, String id) async {
    final AuthContext ctx = await who(req);
    return json(
      await admin.updateAccount(
        ctx,
        uuidParam(id, what: 'That account'),
        await readJson(req),
      ),
    );
  });

  r.post('/v1/admin/accounts/<id>/sign-out', (Request req, String id) async {
    await admin.signOutEverywhere(
      await who(req),
      uuidParam(id, what: 'That account'),
    );
    return json(const <String, Object?>{'status': 'signed_out'});
  });

  r.delete('/v1/admin/accounts/<id>/devices/<deviceId>', (
    Request req,
    String id,
    String deviceId,
  ) async {
    await admin.revokeDevice(
      await who(req),
      uuidParam(id, what: 'That account'),
      uuidParam(deviceId, what: 'That device'),
    );
    return json(const <String, Object?>{'status': 'revoked'});
  });

  r.get('/v1/admin/diagnostics', (Request req) async {
    final AuthContext ctx = await who(req);
    return json(<String, Object?>{
      'diagnostics': await admin.diagnostics(
        ctx,
        level: qStr(req, 'level'),
        accountId: qStr(req, 'account'),
        beforeId: qBefore(req),
        limit: qLimit(req, 100),
      ),
    });
  });

  r.get('/v1/admin/reports', (Request req) async {
    final AuthContext ctx = await who(req);
    return json(<String, Object?>{
      'reports': await admin.reports(
        ctx,
        status: qStr(req, 'status'),
        category: qStr(req, 'category'),
        severity: qStr(req, 'severity'),
        query: qStr(req, 'q'),
        limit: qLimit(req, 100),
        offset: qOffset(req),
      ),
    });
  });

  r.get('/v1/admin/reports/<id>', (Request req, String id) async {
    return json(
      await admin.report(await who(req), uuidParam(id, what: 'That report')),
    );
  });

  r.patch('/v1/admin/reports/<id>', (Request req, String id) async {
    final AuthContext ctx = await who(req);
    return json(
      await admin.updateReport(
        ctx,
        uuidParam(id, what: 'That report'),
        await readJson(req),
      ),
    );
  });

  r.post('/v1/admin/reports/<id>/notes', (Request req, String id) async {
    final AuthContext ctx = await who(req);
    final Map<String, dynamic> b = await readJson(req);
    return json(
      await admin.addReportNote(
        ctx,
        uuidParam(id, what: 'That report'),
        b.str('body', max: ProtocolLimits.maxReportNote),
      ),
    );
  });

  r.get('/v1/admin/sessions', (Request req) async {
    final AuthContext ctx = await who(req);
    return json(<String, Object?>{
      'sessions': await admin.sessions(
        ctx,
        accountId: qStr(req, 'account'),
        sessionId: qStr(req, 'sessionId'),
        query: qStr(req, 'q'),
        sosOnly: qStr(req, 'sos') == 'true',
        since: DateTime.tryParse(qStr(req, 'since') ?? '')?.toUtc(),
        limit: qLimit(req, 100),
      ),
    });
  });

  r.get('/v1/admin/sessions/<sessionId>', (
    Request req,
    String sessionId,
  ) async {
    return json(
      await admin.session(
        await who(req),
        idParam(sessionId, what: 'That session'),
      ),
    );
  });

  r.post('/v1/admin/session-logs/<id>/unseal', (Request req, String id) async {
    final AuthContext ctx = await who(req);
    final Map<String, dynamic> b = await readJson(req);
    return json(
      await admin.unseal(
        ctx,
        uuidParam(id, what: 'That record'),
        reason: b.str('reason', max: ProtocolLimits.maxUnsealReason),
        caseRef: b.optStr('caseRef', max: ProtocolLimits.maxCaseRef),
      ),
    );
  });

  r.get('/v1/admin/audit', (Request req) async {
    final AuthContext ctx = await who(req);
    return json(<String, Object?>{
      'entries': await admin.auditEntries(
        ctx,
        action: qStr(req, 'action'),
        beforeId: qBefore(req),
        limit: qLimit(req, 100),
      ),
    });
  });

  r.get('/v1/admin/audit/verify', (Request req) async {
    return json((await admin.verifyAudit(await who(req))).toJson());
  });

  r.get('/v1/admin/backups', (Request req) async {
    final AuthContext ctx = await who(req);
    ctx.require(AccountRole.admin);
    return json(<String, Object?>{
      'running': backups.isRunning,
      'backups': await backups.list(),
    });
  });

  r.post('/v1/admin/backups', (Request req) async {
    final AuthContext ctx = await who(req);
    ctx.require(AccountRole.admin);
    return json(
      await backups.run(kind: 'manual', actor: ctx.actor),
      status: 201,
    );
  });

  return r;
}

String _b64(List<int> b) => base64.encode(b);
