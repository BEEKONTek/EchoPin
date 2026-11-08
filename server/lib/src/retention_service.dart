// RETENTION: deletes data the organisation no longer needs, automatically.
//
// Keeping emergency records "just in case" forever is itself a risk: every
// old record is one more thing a breach can expose, and POPIA/GDPR expect
// personal data to be kept only as long as needed. Periods are set with
// RETAIN_*_DAYS (0 = keep forever). Runs once a day; each run that removes
// anything writes one `retention.purged` audit entry with the counts.
//
// Never deleted here: the audit log (append-only by design), open reports,
// and refresh-token rows that could still detect a stolen token (they are
// removed only once every token they hold has expired).

import 'dart:async';

import 'package:logging/logging.dart';

import 'config.dart';
import 'db/database.dart';
import 'security/audit.dart';
import 'security/rate_limit.dart';

final Logger _log = Logger('retention');

class RetentionService {
  RetentionService({
    required Db db,
    required ServerConfig config,
    required AuditLog audit,
    DateTime Function()? clock,
  }) : _db = db,
       _config = config,
       _audit = audit,
       _clock = clock ?? DateTime.now;

  final Db _db;
  final ServerConfig _config;
  final AuditLog _audit;
  final DateTime Function() _clock;
  Timer? _timer;

  /// First run a few minutes after start, then daily.
  void startSchedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(minutes: 5), () {
      unawaited(_safeRun());
      _timer = Timer.periodic(const Duration(hours: 24), (_) => unawaited(_safeRun()));
    });
  }

  void stop() => _timer?.cancel();

  Future<void> _safeRun() async {
    try {
      await run();
    } catch (e, st) {
      _log.severe('Retention run failed', e, st);
    }
  }

  /// Deletes everything past its retention period; returns counts by kind.
  Future<Map<String, int>> run() async {
    final DateTime now = _clock().toUtc();
    DateTime? cutoff(int days) => days <= 0 ? null : now.subtract(Duration(days: days));
    final Map<String, int> removed = <String, int>{};

    final DateTime? logs = cutoff(_config.retainSessionLogsDays);
    if (logs != null) {
      // unseal_grants cascade with their log; the audit log keeps the record
      // of every opening permanently.
      removed['sessionLogs'] = await _db.execute(
        'delete from session_logs where started_at < @t',
        <String, Object?>{'t': logs},
      );
    }
    final DateTime? diag = cutoff(_config.retainDiagnosticsDays);
    if (diag != null) {
      removed['diagnostics'] = await _db.execute(
        'delete from diagnostics where received_at < @t',
        <String, Object?>{'t': diag},
      );
    }
    final DateTime? reports = cutoff(_config.retainClosedReportsDays);
    if (reports != null) {
      removed['closedReports'] = await _db.execute(
        '''delete from reports where status in ('resolved', 'dismissed') and updated_at < @t''',
        <String, Object?>{'t': reports},
      );
    }
    // Housekeeping with fixed periods: nothing here is useful once expired.
    removed['emailCodes'] = await _db.execute(
      'delete from email_codes where expires_at < @t',
      <String, Object?>{'t': now.subtract(const Duration(days: 2))},
    );
    removed['authSessions'] = await _db.execute(
      'delete from auth_sessions where refresh_expires_at < @t',
      <String, Object?>{'t': now.subtract(const Duration(days: 1))},
    );
    removed['loginThrottle'] = await _db.execute(
      '''delete from login_throttle where updated_at < @t
           and (locked_until is null or locked_until < @now)''',
      <String, Object?>{'t': now.subtract(const Duration(days: 2)), 'now': now},
    );
    removed['rateCounters'] = await DbRateLimiter.prune(_db, now);

    removed.removeWhere((_, int n) => n == 0);
    if (removed.isNotEmpty) {
      await _audit.record(_db, const AuditActor.system('retention'), 'retention.purged',
          detail: removed);
      _log.info('Retention removed $removed');
    }
    return removed;
  }
}
