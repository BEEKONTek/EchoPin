import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:logging/logging.dart';

import 'api/http.dart';
import 'auth/auth_service.dart';
import 'db/database.dart';
import 'mail/mailer.dart';
import 'security/audit.dart';
import 'security/keys.dart';
import 'security/rate_limit.dart';

final Logger _log = Logger('admin');

/// The central console: cross-system overview, people, diagnostics,
/// reports, the session index, break-glass access and the audit trail.
///
/// Roles: responders see reports and sessions and may open sealed logs by
/// stating a reason; admins see and do everything. Each method checks the
/// role itself instead of trusting the route.
class AdminService {
  AdminService({
    required Db db,
    required ServerKeys keys,
    required AuditLog audit,
    required AuthService auth,
    Limiter? limiter,
    Mailer? mailer,
    this.unsealAlerts = false,
    Future<({int id, String hash})?> Function()? auditAnchor,
    DateTime Function()? clock,
  }) : _db = db,
       _keys = keys,
       _audit = audit,
       _auth = auth,
       _limiter = limiter ?? RateLimiter(clock: clock),
       _mailer = mailer,
       _auditAnchor = auditAnchor,
       _clock = clock ?? DateTime.now;

  final Db _db;
  final ServerKeys _keys;
  final AuditLog _audit;
  final AuthService _auth;
  final Limiter _limiter;
  final Mailer? _mailer;
  final Future<({int id, String hash})?> Function()? _auditAnchor;
  final DateTime Function() _clock;

  /// Email every active admin whenever a session record is opened.
  final bool unsealAlerts;

  DateTime get _now => _clock().toUtc();

  // ── Overview ───────────────────────────────────────────────────────────

  Future<Map<String, Object?>> overview(AuthContext ctx) async {
    ctx.require(AccountRole.responder);
    final DateTime now = _now;
    final DateTime day = now.subtract(const Duration(days: 1));
    final DateTime week = now.subtract(const Duration(days: 7));
    final DateTime month = now.subtract(const Duration(days: 30));
    final Row c = (await _db.one(
      '''select
        (select count(*) from accounts where status = 'active')::int as active_accounts,
        (select count(*) from accounts where status = 'pending')::int as pending_accounts,
        (select count(*) from accounts where status = 'disabled')::int as disabled_accounts,
        (select count(*) from devices where revoked_at is null and last_seen_at > @day)::int as devices_24h,
        (select count(*) from diagnostics where level = 'error' and received_at > @day)::int as errors_24h,
        (select count(*) from diagnostics where level = 'warning' and received_at > @day)::int as warnings_24h,
        (select count(*) from reports where status in ('open', 'investigating'))::int as open_reports,
        (select count(*) from reports where status in ('open', 'investigating')
                                      and severity = 'critical')::int as critical_reports,
        (select count(distinct session_id) from session_logs where started_at > @day)::int as sessions_24h,
        (select count(distinct session_id) from session_logs where started_at > @week)::int as sessions_7d,
        (select count(distinct session_id) from session_logs
          where started_at > @week and sos_count > 0)::int as sos_sessions_7d''',
      <String, Object?>{'day': day, 'week': week},
    ))!;
    final List<Row> versions = await _db.query(
      '''select platform, coalesce(app_version, '?') as app_version, count(*)::int as devices
           from devices where revoked_at is null and last_seen_at > @month
          group by 1, 2 order by 3 desc limit 20''',
      <String, Object?>{'month': month},
    );
    final List<Row> daily = await _db.query(
      '''with days as (
           select generate_series(date_trunc('day', @from::timestamptz),
                                  date_trunc('day', @now::timestamptz), interval '1 day') as d)
         select days.d as day,
           (select count(distinct session_id) from session_logs
             where started_at >= days.d and started_at < days.d + interval '1 day')::int as sessions,
           -- Distinct sessions, like the tiles: every member's phone uploads
           -- its own record, so counting rows would multiply each SOS.
           (select count(distinct session_id) from session_logs
             where started_at >= days.d and started_at < days.d + interval '1 day'
               and sos_count > 0)::int as sos,
           (select count(*) from diagnostics
             where level = 'error' and received_at >= days.d
               and received_at < days.d + interval '1 day')::int as errors,
           (select count(*) from reports
             where created_at >= days.d and created_at < days.d + interval '1 day')::int as reports
         from days order by days.d''',
      <String, Object?>{'from': now.subtract(const Duration(days: 13)), 'now': now},
    );
    final Row? lastBackup = await _db.one(
      '''select status, file_name, size_bytes, started_at, error from backups
          where status in ('ok', 'failed') order by started_at desc limit 1''',
    );
    return <String, Object?>{
      'generatedAt': now,
      'accounts': <String, Object?>{
        'active': c['active_accounts'],
        'pending': c['pending_accounts'],
        'disabled': c['disabled_accounts'],
      },
      'devicesActive24h': c['devices_24h'],
      'diagnostics24h': <String, Object?>{
        'errors': c['errors_24h'],
        'warnings': c['warnings_24h'],
      },
      'reports': <String, Object?>{
        'open': c['open_reports'],
        'critical': c['critical_reports'],
      },
      'sessions': <String, Object?>{
        'last24h': c['sessions_24h'],
        'last7d': c['sessions_7d'],
        'withSos7d': c['sos_sessions_7d'],
      },
      'versions': versions
          .map(
            (Row r) => <String, Object?>{
              'platform': r['platform'],
              'appVersion': r['app_version'],
              'devices': r['devices'],
            },
          )
          .toList(),
      'daily': daily
          .map(
            (Row r) => <String, Object?>{
              'day': r['day'],
              'sessions': r['sessions'],
              'sos': r['sos'],
              'errors': r['errors'],
              'reports': r['reports'],
            },
          )
          .toList(),
      'lastBackup': lastBackup == null
          ? null
          : <String, Object?>{
              'status': lastBackup['status'],
              'fileName': lastBackup['file_name'],
              'sizeBytes': lastBackup['size_bytes'],
              'startedAt': lastBackup['started_at'],
              'error': lastBackup['error'],
            },
    };
  }

  // ── Accounts ───────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> accounts(
    AuthContext ctx, {
    String? query,
    String? role,
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    ctx.require(AccountRole.admin);
    final List<Row> rows = await _db.query(
      '''select a.id, a.email, a.display_name, a.role, a.status, a.created_at,
                a.last_login_at, a.totp_secret_enc is not null as totp_enabled,
                lt.locked_until,
                (select count(*) from devices d
                  where d.account_id = a.id and d.revoked_at is null)::int as devices
           from accounts a
           left join login_throttle lt on lt.email = a.email_normalized
          where (@q::text is null or a.email_normalized like @like or
                 lower(a.display_name) like @like)
            and (@role::text is null or a.role = @role)
            and (@status::text is null or a.status = @status)
          order by a.created_at desc
          limit @limit offset @offset''',
      <String, Object?>{
        'q': query,
        'like': query == null ? null : '%${_escapeLike(query.toLowerCase())}%',
        'role': role,
        'status': status,
        'limit': limit.clamp(1, 200),
        'offset': offset.clamp(0, 1 << 30),
      },
    );
    return rows.map(_accountRow).toList();
  }

  Future<Map<String, Object?>> account(AuthContext ctx, String id) async {
    ctx.require(AccountRole.admin);
    final Row? a = await _db.one(
      '''select a.id, a.email, a.display_name, a.role, a.status, a.created_at,
                a.last_login_at, a.totp_secret_enc is not null as totp_enabled,
                lt.locked_until, coalesce(lt.failures, 0) as failed_logins, a.email_verified_at,
                (select count(*) from devices d
                  where d.account_id = a.id and d.revoked_at is null)::int as devices
           from accounts a
           left join login_throttle lt on lt.email = a.email_normalized
          where a.id = @id::uuid''',
      <String, Object?>{'id': id},
    );
    if (a == null) throw ApiException.notFound('That account');
    final List<Row> sessions = await _db.query(
      '''select id, session_id, session_name, started_at, ended_at, member_count,
                sos_count, help_count
           from session_logs where account_id = @id::uuid
          order by started_at desc limit 20''',
      <String, Object?>{'id': id},
    );
    final List<Row> reports = await _db.query(
      '''select id, category, severity, status, subject, created_at
           from reports where account_id = @id::uuid order by created_at desc limit 20''',
      <String, Object?>{'id': id},
    );
    return <String, Object?>{
      ..._accountRow(a),
      'failedLogins': a['failed_logins'],
      'emailVerifiedAt': a['email_verified_at'],
      'deviceList': await _auth.devices(id),
      'recentSessions': sessions.map(_logRow).toList(),
      'recentReports': reports
          .map(
            (Row r) => <String, Object?>{
              'id': r['id'],
              'category': r['category'],
              'severity': r['severity'],
              'status': r['status'],
              'subject': r['subject'],
              'createdAt': r['created_at'],
            },
          )
          .toList(),
    };
  }

  Future<Map<String, Object?>> updateAccount(
    AuthContext ctx,
    String id,
    Map<String, dynamic> body,
  ) async {
    ctx.require(AccountRole.admin);
    final AccountRole? role = body['role'] == null
        ? null
        : (AccountRole.fromWire(body['role']) ??
              (throw ApiException.badRequest('role must be member, responder or admin')));
    final AccountStatus? status = body['status'] == null
        ? null
        : (AccountStatus.fromWire(body['status']) ??
              (throw ApiException.badRequest('status must be active or disabled')));
    if (status == AccountStatus.pending) {
      throw ApiException.badRequest('An account cannot be set back to pending');
    }
    final bool unlock = body['unlock'] == true;
    // Lost authenticator: an admin can switch two-step off so the person
    // can sign in with their password and set it up again. Signs them out
    // everywhere, because whoever has the old authenticator might be the
    // reason for the reset.
    final bool resetTwoStep = body['resetTwoStep'] == true;
    if (role == null && status == null && !unlock && !resetTwoStep) {
      throw ApiException.badRequest('Nothing to change');
    }
    if (id == ctx.accountId && (role != null || status != null)) {
      throw const ApiException(
        409,
        'self_change',
        'You cannot change your own role or status. Ask another admin',
      );
    }
    await _db.tx((DbSession tx) async {
      final Row? before = await tx.one(
        'select role, status from accounts where id = @id::uuid for update',
        <String, Object?>{'id': id},
      );
      if (before == null) throw ApiException.notFound('That account');
      final bool losingAdmin =
          before['role'] == 'admin' &&
          ((role != null && role != AccountRole.admin) || status == AccountStatus.disabled);
      if (losingAdmin) {
        final Row n = (await tx.one(
          '''select count(*)::int as n from accounts
              where role = 'admin' and status = 'active' and id <> @id::uuid''',
          <String, Object?>{'id': id},
        ))!;
        if ((n['n'] as int) == 0) {
          throw const ApiException(
            409,
            'last_admin',
            'This is the last active admin. Make someone else an admin first',
          );
        }
      }
      await tx.execute(
        '''update accounts set
             role = coalesce(@role, role),
             status = coalesce(@status, status),
             totp_secret_enc = case when @reset2 then null else totp_secret_enc end,
             totp_pending_enc = case when @reset2 then null else totp_pending_enc end,
             totp_last_step = case when @reset2 then null else totp_last_step end,
             updated_at = @now
           where id = @id::uuid''',
        <String, Object?>{
          'role': role?.wire,
          'status': status?.wire,
          'reset2': resetTwoStep,
          'now': _now,
          'id': id,
        },
      );
      if (unlock) {
        await tx.execute(
          '''delete from login_throttle
              where email = (select email_normalized from accounts where id = @id::uuid)''',
          <String, Object?>{'id': id},
        );
      }
      if (status == AccountStatus.disabled || resetTwoStep) {
        await tx.execute(
          '''update auth_sessions set revoked_at = @now, revoked_reason = @why
             where account_id = @id::uuid and revoked_at is null''',
          <String, Object?>{
            'now': _now,
            'id': id,
            'why': status == AccountStatus.disabled ? 'account_disabled' : 'two_step_reset',
          },
        );
      }
      await _audit.recordIn(
        tx,
        ctx.actor,
        'account.updated',
        target: id,
        detail: <String, Object?>{
          if (role != null) 'role': '${before['role']} → ${role.wire}',
          if (status != null) 'status': '${before['status']} → ${status.wire}',
          if (unlock) 'unlocked': true,
          if (resetTwoStep) 'twoStepReset': true,
        },
      );
    });
    return account(ctx, id);
  }

  Future<void> signOutEverywhere(AuthContext ctx, String id) async {
    ctx.require(AccountRole.admin);
    final int n = await _auth.revokeAllSessions(id, 'admin_signout');
    await _audit.record(_db, ctx.actor, 'account.signed_out_everywhere', target: id,
        detail: <String, Object?>{'sessions': n});
  }

  Future<void> revokeDevice(AuthContext ctx, String accountId, String deviceId) {
    ctx.require(AccountRole.admin);
    return _auth.revokeDevice(accountId, deviceId, ctx.actor);
  }

  // ── Diagnostics ────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> diagnostics(
    AuthContext ctx, {
    String? level,
    String? accountId,
    int? beforeId,
    int limit = 100,
  }) async {
    ctx.require(AccountRole.admin);
    final List<Row> rows = await _db.query(
      '''select g.id, g.level, g.app_version, g.platform, g.summary, g.payload,
                g.received_at, g.account_id, a.email, d.label as device
           from diagnostics g
           left join accounts a on a.id = g.account_id
           left join devices d on d.id = g.device_id
          where (@level::text is null or g.level = @level)
            and (@acct::uuid is null or g.account_id = @acct::uuid)
            and (@before::bigint is null or g.id < @before::bigint)
          order by g.id desc limit @limit''',
      <String, Object?>{
        'level': level,
        'acct': accountId,
        'before': beforeId,
        'limit': limit.clamp(1, 500),
      },
    );
    return rows
        .map(
          (Row r) => <String, Object?>{
            'id': r['id'],
            'level': r['level'],
            'appVersion': r['app_version'],
            'platform': r['platform'],
            'summary': r['summary'],
            'payload': r['payload'],
            'receivedAt': r['received_at'],
            'accountId': r['account_id'],
            'email': r['email'],
            'device': r['device'],
          },
        )
        .toList();
  }

  // ── Reports ────────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> reports(
    AuthContext ctx, {
    String? status,
    String? category,
    String? severity,
    String? query,
    int limit = 100,
    int offset = 0,
  }) async {
    ctx.require(AccountRole.responder);
    // "active" (the default) means open or investigating.
    final List<String> statuses = switch (status) {
      null || 'active' => <String>['open', 'investigating'],
      'all' => <String>['open', 'investigating', 'resolved', 'dismissed'],
      final String s => <String>[s],
    };
    final List<Row> rows = await _db.query(
      '''select r.id, r.category, r.severity, r.status, r.subject, r.session_id,
                r.created_at, r.updated_at, a.email, a.display_name,
                asg.display_name as assignee,
                (select count(*) from report_notes n where n.report_id = r.id)::int as notes
           from reports r
           left join accounts a on a.id = r.account_id
           left join accounts asg on asg.id = r.assignee_id
          where r.status = any(@statuses)
            and (@category::text is null or r.category = @category)
            and (@severity::text is null or r.severity = @severity)
            and (@q::text is null or lower(r.subject) like @like or lower(r.body) like @like)
          order by case r.severity when 'critical' then 0 when 'high' then 1
                                   when 'normal' then 2 else 3 end,
                   r.created_at desc
          limit @limit offset @offset''',
      <String, Object?>{
        'statuses': statuses,
        'category': category,
        'severity': severity,
        'q': query,
        'like': query == null ? null : '%${_escapeLike(query.toLowerCase())}%',
        'limit': limit.clamp(1, 200),
        'offset': offset.clamp(0, 1 << 30),
      },
    );
    return rows
        .map(
          (Row r) => <String, Object?>{
            'id': r['id'],
            'category': r['category'],
            'severity': r['severity'],
            'status': r['status'],
            'subject': r['subject'],
            'sessionId': r['session_id'],
            'createdAt': r['created_at'],
            'updatedAt': r['updated_at'],
            // Data minimisation: responders work from the name; only admins
            // (who manage accounts) see contact details.
            if (ctx.role.atLeast(AccountRole.admin)) 'reporterEmail': r['email'],
            'reporterName': r['display_name'],
            'assignee': r['assignee'],
            'notes': r['notes'],
          },
        )
        .toList();
  }

  Future<Map<String, Object?>> report(AuthContext ctx, String id) async {
    ctx.require(AccountRole.responder);
    final Row? r = await _db.one(
      '''select r.*, a.email, a.display_name, asg.display_name as assignee_name,
                dv.label as device_label
           from reports r
           left join accounts a on a.id = r.account_id
           left join accounts asg on asg.id = r.assignee_id
           left join devices dv on dv.id = r.device_id
          where r.id = @id::uuid''',
      <String, Object?>{'id': id},
    );
    if (r == null) throw ApiException.notFound('That report');
    final List<Row> notes = await _db.query(
      '''select n.id, n.body, n.created_at, a.display_name as author
           from report_notes n left join accounts a on a.id = n.author_id
          where n.report_id = @id::uuid order by n.created_at''',
      <String, Object?>{'id': id},
    );
    return <String, Object?>{
      'id': r['id'],
      'category': r['category'],
      'severity': r['severity'],
      'status': r['status'],
      'subject': r['subject'],
      'body': r['body'],
      'sessionId': r['session_id'],
      'diagnostics': r['diagnostics'],
      'resolution': r['resolution'],
      'createdAt': r['created_at'],
      'updatedAt': r['updated_at'],
      'reporterId': r['account_id'],
      if (ctx.role.atLeast(AccountRole.admin)) 'reporterEmail': r['email'],
      'reporterName': r['display_name'],
      'device': r['device_label'],
      'assigneeId': r['assignee_id'],
      'assignee': r['assignee_name'],
      'notes': notes
          .map(
            (Row n) => <String, Object?>{
              'id': n['id'],
              'body': n['body'],
              'author': n['author'],
              'createdAt': n['created_at'],
            },
          )
          .toList(),
    };
  }

  Future<Map<String, Object?>> updateReport(
    AuthContext ctx,
    String id,
    Map<String, dynamic> body,
  ) async {
    ctx.require(AccountRole.responder);
    final ReportStatus? status = body['status'] == null
        ? null
        : (ReportStatus.fromWire(body['status']) ??
              (throw ApiException.badRequest('Unknown status')));
    final ReportSeverity? severity = body['severity'] == null
        ? null
        : (ReportSeverity.fromWire(body['severity']) ??
              (throw ApiException.badRequest('Unknown severity')));
    final bool assignSelf = body['assignToMe'] == true;
    final bool unassign = body['unassign'] == true;
    final String? resolution = body.optStr('resolution', max: 2000);
    if (status != null && status.isClosed && resolution == null) {
      throw ApiException.badRequest('Say how it was resolved before closing it');
    }
    await _db.tx((DbSession tx) async {
      final int n = await tx.execute(
        '''update reports set
             status = coalesce(@status, status),
             severity = coalesce(@severity, severity),
             assignee_id = case when @self then @me::uuid
                                when @unassign then null else assignee_id end,
             resolution = coalesce(@resolution, resolution),
             updated_at = @now
           where id = @id::uuid''',
        <String, Object?>{
          'status': status?.wire,
          'severity': severity?.wire,
          'self': assignSelf,
          'unassign': unassign,
          'me': ctx.accountId,
          'resolution': resolution,
          'now': _now,
          'id': id,
        },
      );
      if (n == 0) throw ApiException.notFound('That report');
      await _audit.recordIn(tx, ctx.actor, 'report.updated', target: id,
          detail: <String, Object?>{
            if (status != null) 'status': status.wire,
            if (severity != null) 'severity': severity.wire,
            if (assignSelf) 'assignee': ctx.email,
            if (unassign) 'assignee': null,
          });
    });
    return report(ctx, id);
  }

  Future<Map<String, Object?>> addReportNote(AuthContext ctx, String id, String body) async {
    ctx.require(AccountRole.responder);
    final Row? exists = await _db.one(
      'select 1 as x from reports where id = @id::uuid',
      <String, Object?>{'id': id},
    );
    if (exists == null) throw ApiException.notFound('That report');
    await _db.tx((DbSession tx) async {
      await tx.execute(
        '''insert into report_notes (report_id, author_id, body, created_at)
           values (@r::uuid, @a::uuid, @b, @now)''',
        <String, Object?>{'r': id, 'a': ctx.accountId, 'b': body, 'now': _now},
      );
      await tx.execute(
        'update reports set updated_at = @now where id = @id::uuid',
        <String, Object?>{'now': _now, 'id': id},
      );
      await _audit.recordIn(tx, ctx.actor, 'report.note_added', target: id);
    });
    return report(ctx, id);
  }

  // ── Sessions and break-glass ───────────────────────────────────────────

  /// One row per session (all members' uploads grouped). Metadata only.
  Future<List<Map<String, Object?>>> sessions(
    AuthContext ctx, {
    String? accountId,
    String? sessionId,
    String? query,
    bool sosOnly = false,
    DateTime? since,
    int limit = 100,
  }) async {
    ctx.require(AccountRole.responder);
    // Looking a *person* up is recorded: browsing the list is routine, but
    // "show me everything this account took part in" should leave a trace.
    if (accountId != null || query != null) {
      await _audit.record(_db, ctx.actor, 'sessions.searched',
          target: accountId, detail: <String, Object?>{'query': ?query});
    }
    final List<Row> rows = await _db.query(
      '''with latest as (
           select distinct on (session_id, device_id) *
             from session_logs
            order by session_id, device_id, sequence desc, received_at desc)
         select l.session_id, max(l.session_name) as name,
                min(l.started_at) as started_at, max(l.ended_at) as ended_at,
                count(*)::int as uploads, max(l.member_count)::int as members,
                -- Every member's phone sees the same SOS, check-in or need-help
                -- and records it, so summing their views would multiply one
                -- event by the number of phones. Show the most any one saw.
                max(l.sos_count)::int as sos, max(l.help_count)::int as help,
                max(l.checkin_count)::int as checkins,
                max(l.crossing_count)::int as crossings,
                bool_and(l.is_final) as finished,
                count(distinct l.session_tag)::int as tags,
                bool_or(l.session_tag is null) as untagged,
                array_agg(distinct coalesce(a.display_name, '?')) as people,
                (select count(*) from unseal_grants g
                   join session_logs l2 on l2.id = g.session_log_id
                  where l2.session_id = l.session_id)::int as times_opened
           from latest l left join accounts a on a.id = l.account_id
          where (@acct::uuid is null or l.session_id in
                   (select session_id from session_logs where account_id = @acct::uuid))
            and (@sid::text is null or l.session_id = @sid)
            and (@q::text is null or lower(l.session_name) like @like
                 or l.session_id in (select l3.session_id from session_logs l3
                                       join accounts a3 on a3.id = l3.account_id
                                      where a3.email_normalized like @like
                                         or lower(a3.display_name) like @like))
            and (@since::timestamptz is null or l.started_at >= @since)
          group by l.session_id
         having (not @sos or max(l.sos_count) > 0)
          order by min(l.started_at) desc
          limit @limit''',
      <String, Object?>{
        'acct': accountId,
        'sid': sessionId,
        'q': query,
        'like': query == null ? null : '%${_escapeLike(query.toLowerCase())}%',
        'since': since,
        'sos': sosOnly,
        'limit': limit.clamp(1, 500),
      },
    );
    return rows
        .map(
          (Row r) => <String, Object?>{
            'sessionId': r['session_id'],
            'name': r['name'],
            'startedAt': r['started_at'],
            'endedAt': r['ended_at'],
            'uploads': r['uploads'],
            'members': r['members'],
            'sos': r['sos'],
            'help': r['help'],
            'checkIns': r['checkins'],
            'crossings': r['crossings'],
            'people': r['people'],
            'finished': r['finished'],
            'timesOpened': r['times_opened'],
            // Uploads that disagree on the session tag: at least one came
            // from someone who did not know the session key (see session()).
            'unproven': (r['tags'] as int) > 1 || ((r['tags'] as int) == 1 && r['untagged'] == true),
          },
        )
        .toList();
  }

  /// Every member's upload for one session, plus who has opened which.
  Future<Map<String, Object?>> session(AuthContext ctx, String sessionId) async {
    ctx.require(AccountRole.responder);
    final List<Row> logs = await _db.query(
      '''select l.id, l.session_id, l.session_name, l.started_at, l.ended_at,
                l.member_count, l.sos_count, l.help_count, l.checkin_count,
                l.crossing_count, l.end_reason, l.received_at, l.sequence, l.is_final,
                l.session_tag, l.custodian_key_id,
                a.id as account_id, a.email, a.display_name, d.label as device
           from session_logs l
           left join accounts a on a.id = l.account_id
           left join devices d on d.id = l.device_id
          where l.session_id = @sid order by a.display_name, l.sequence''',
      <String, Object?>{'sid': sessionId},
    );
    if (logs.isEmpty) throw ApiException.notFound('That session');
    await _audit.record(_db, ctx.actor, 'session.viewed', target: sessionId);
    // Session tag check. Every member derives the same tag from the session
    // key, which only people holding the invite code know. The session id
    // alone is public (it is advertised over Bluetooth), so an outsider can
    // upload under it, but can't produce the tag.
    //
    // Votes are *people*, not uploads: an outsider sending ten checkpoints
    // still counts once. A tag is accepted only when a strict majority of
    // the people who sent tagged uploads share it. On a tie (say one real
    // member and one outsider) nobody can tell which side is genuine, so
    // every upload is shown as unknown instead of guessing; guessing wrong
    // would brand the real member's emergency record as fake.
    final Map<String, Set<String>> tagPeople = <String, Set<String>>{};
    for (final Row r in logs) {
      final List<int>? t = r['session_tag'] as List<int>?;
      if (t == null) continue;
      tagPeople
          .putIfAbsent(base64.encode(t), () => <String>{})
          .add(r['account_id'] as String? ?? 'deleted:${r['id']}');
    }
    String? majority;
    final int voters = tagPeople.values.fold(0, (int n, Set<String> p) => n + p.length);
    for (final MapEntry<String, Set<String>> e in tagPeople.entries) {
      if (e.value.length * 2 > voters) majority = e.key;
    }
    final bool tagsDisagree = tagPeople.length > 1;
    final bool admin = ctx.role.atLeast(AccountRole.admin);
    final List<Row> grants = await _db.query(
      '''select g.session_log_id, g.reason, g.case_ref, g.created_at,
                a.display_name, a.email
           from unseal_grants g
           join session_logs l on l.id = g.session_log_id
           join accounts a on a.id = g.account_id
          where l.session_id = @sid order by g.created_at desc''',
      <String, Object?>{'sid': sessionId},
    );
    return <String, Object?>{
      'sessionId': sessionId,
      'name': logs.first['session_name'],
      'logs': logs
          .map(
            (Row r) => <String, Object?>{
              ..._logRow(r),
              'accountId': r['account_id'],
              if (admin) 'email': r['email'],
              'displayName': r['display_name'],
              'device': r['device'],
              'endReason': r['end_reason'],
              'receivedAt': r['received_at'],
              'sequence': r['sequence'],
              'final': r['is_final'],
              // true: matches the majority of people; false: does not (or has
              // no tag while others do); null: no tags, or a tie.
              'memberProven': majority == null
                  ? null
                  : (r['session_tag'] != null && base64.encode(r['session_tag'] as List<int>) == majority),
              'tagsDisagree': tagsDisagree,
              'doubleSealed': r['custodian_key_id'] != null,
            },
          )
          .toList(),
      'accessHistory': grants
          .map(
            (Row g) => <String, Object?>{
              'logId': g['session_log_id'],
              'by': g['display_name'],
              if (admin) 'email': g['email'],
              'reason': g['reason'],
              'caseRef': g['case_ref'],
              'at': g['created_at'],
            },
          )
          .toList(),
    };
  }

  /// Break-glass: opens one sealed log. The grant and its reason are
  /// written to the audit chain *before* decryption, in the same
  /// transaction, so there is no way to read a log without leaving a trace.
  Future<Map<String, Object?>> unseal(
    AuthContext ctx,
    String logId, {
    required String reason,
    String? caseRef,
  }) async {
    ctx.require(AccountRole.responder);
    if (reason.trim().length < 10) {
      throw ApiException.badRequest(
        'Describe why you need this log (at least 10 characters). It is '
        'recorded permanently',
        code: 'reason_required',
      );
    }
    final Duration? wait = await _limiter.hit(
      'unseal:${ctx.accountId}',
      limit: 30,
      window: const Duration(hours: 1),
    );
    if (wait != null) throw ApiException.tooMany(wait);

    final Row log = await _db.tx((DbSession tx) async {
      final Row? l = await tx.one(
        '''select id, session_id, session_name, key_id, sealed, custodian_key_id
             from session_logs where id = @id::uuid''',
        <String, Object?>{'id': logId},
      );
      if (l == null) throw ApiException.notFound('That session log');
      await tx.execute(
        '''insert into unseal_grants (session_log_id, account_id, reason, case_ref, created_at)
           values (@l::uuid, @a::uuid, @r, @c, @now)''',
        <String, Object?>{
          'l': logId,
          'a': ctx.accountId,
          'r': reason.trim(),
          'c': caseRef,
          'now': _now,
        },
      );
      await _audit.recordIn(tx, ctx.actor, 'session_log.unsealed', target: logId,
          detail: <String, Object?>{
            'sessionId': l['session_id'],
            'reason': reason.trim(),
            'caseRef': caseRef,
          });
      return l;
    });
    _alertAdmins(ctx, log, reason.trim(), caseRef);

    final SimpleKeyPair? key = _keys.escrowKeys[log['key_id']];
    if (key == null) {
      throw const ApiException(
        500,
        'escrow_key_missing',
        'The key for this log is not on this server. Restore the keys directory',
      );
    }
    try {
      final List<int> clear = await SealedBox.open(
        recipient: key,
        sealed: log['sealed'] as List<int>,
        context: 'session-log:$logId',
      );
      final String? custodianKeyId = log['custodian_key_id'] as String?;
      if (custodianKeyId != null) {
        // Double-sealed: what's inside the server's layer is still sealed to
        // the custodian key, which only responders' devices hold. Hand it
        // over as is; the console opens it locally. The server never sees
        // the record's contents.
        return <String, Object?>{
          'logId': logId,
          'sessionId': log['session_id'],
          'custodianKeyId': custodianKeyId,
          'sealedInner': base64.encode(clear),
        };
      }
      return <String, Object?>{
        'logId': logId,
        'sessionId': log['session_id'],
        'content': jsonDecode(utf8.decode(clear)),
      };
    } catch (e) {
      _log.severe('Unseal of $logId failed', e);
      throw const ApiException(
        500,
        'unseal_failed',
        'This log could not be opened. It may be damaged. The attempt was recorded',
      );
    }
  }

  /// Break-glass alert: tells every active admin, by email, that a record
  /// was opened, by whom and why. Abuse then can't wait for someone to
  /// happen to read the audit log. Sent in the background; a mail failure
  /// never blocks an emergency.
  void _alertAdmins(AuthContext ctx, Row log, String reason, String? caseRef) {
    final Mailer? mailer = _mailer;
    if (!unsealAlerts || mailer == null) return;
    unawaited(() async {
      try {
        final List<Row> admins = await _db.query(
          "select email from accounts where role = 'admin' and status = 'active'",
        );
        for (final Row a in admins) {
          await mailer.send(OutgoingMail(
            to: a['email'] as String,
            subject: 'EchoPin: ${ctx.displayName} opened a session record',
            text: '${ctx.displayName} (${ctx.email}) opened a sealed session record.\n\n'
                'Session: ${log['session_name']} (${log['session_id']})\n'
                'Reason given: $reason\n'
                '${caseRef == null ? '' : 'Case reference: $caseRef\n'}'
                'Time: ${_now.toIso8601String()}\n\n'
                'Every opening is in Console → Audit. If this was not expected, '
                'check with them and consider removing their responder role.',
          ));
        }
      } catch (e) {
        _log.severe('Unseal alert email failed', e);
      }
    }());
  }

  // ── Audit ──────────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> auditEntries(
    AuthContext ctx, {
    String? action,
    int? beforeId,
    int limit = 100,
  }) async {
    ctx.require(AccountRole.admin);
    final List<Row> rows = await _db.query(
      '''select id, at, actor_id, actor_label, action, target, detail, ip
           from audit_log
          where (@action::text is null or action like @prefix)
            and (@before::bigint is null or id < @before::bigint)
          order by id desc limit @limit''',
      <String, Object?>{
        'action': action,
        'prefix': action == null ? null : '${_escapeLike(action)}%',
        'before': beforeId,
        'limit': limit.clamp(1, 500),
      },
    );
    return rows
        .map(
          (Row r) => <String, Object?>{
            'id': r['id'],
            'at': r['at'],
            'actorId': r['actor_id'],
            'actor': r['actor_label'],
            'action': r['action'],
            'target': r['target'],
            'detail': jsonDecode(r['detail'] as String),
            'ip': r['ip'],
          },
        )
        .toList();
  }

  Future<AuditVerification> verifyAudit(AuthContext ctx) async {
    ctx.require(AccountRole.admin);
    final ({int id, String hash})? anchor = await _auditAnchor?.call();
    return _audit.verify(_db, anchorId: anchor?.id, anchorHash: anchor?.hash);
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  static Map<String, Object?> _accountRow(Row a) => <String, Object?>{
    'id': a['id'],
    'email': a['email'],
    'displayName': a['display_name'],
    'role': a['role'],
    'status': a['status'],
    'createdAt': a['created_at'],
    'lastLoginAt': a['last_login_at'],
    'totpEnabled': a['totp_enabled'],
    'lockedUntil': a['locked_until'],
    'devices': a['devices'],
  };

  static Map<String, Object?> _logRow(Row r) => <String, Object?>{
    'id': r['id'],
    'sessionId': r['session_id'],
    'sessionName': r['session_name'],
    'startedAt': r['started_at'],
    'endedAt': r['ended_at'],
    'members': r['member_count'],
    'sos': r['sos_count'],
    'help': r['help_count'],
    if (r.containsKey('checkin_count')) 'checkIns': r['checkin_count'],
    if (r.containsKey('crossing_count')) 'crossings': r['crossing_count'],
  };

  static String _escapeLike(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
}
