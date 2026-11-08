/// EchoPin central server: accounts, reports, sealed session logs, audit
/// and backups.
library;

import 'package:shelf/shelf.dart';

import 'src/admin_service.dart';
import 'src/api/http.dart';
import 'src/api/routes.dart';
import 'src/auth/auth_service.dart';
import 'src/auth/passwords.dart';
import 'src/backup/backup_service.dart';
import 'src/config.dart';
import 'src/db/database.dart';
import 'src/mail/mailer.dart';
import 'src/security/audit.dart';
import 'src/security/keys.dart';
import 'src/security/rate_limit.dart';
import 'src/retention_service.dart';
import 'src/security/custodian.dart';
import 'src/auth/breach_check.dart';
import 'src/telemetry_service.dart';

export 'src/admin_service.dart';
export 'src/api/http.dart' show ApiException, ClientIpPolicy, clientIp;
export 'src/api/routes.dart' show serverVersion;
export 'src/auth/auth_service.dart';
export 'src/auth/passwords.dart';
export 'src/auth/totp.dart';
export 'src/backup/backup_service.dart';
export 'src/config.dart';
export 'src/db/database.dart';
export 'src/db/migrations.dart';
export 'src/mail/mailer.dart';
export 'src/security/audit.dart';
export 'src/security/keys.dart';
export 'src/telemetry_service.dart';
export 'src/retention_service.dart';
export 'src/security/custodian.dart';
export 'src/security/rate_limit.dart' show Limiter, RateLimiter, DbRateLimiter;
export 'src/auth/breach_check.dart';

/// Composition root. Owns no I/O of its own; [handler] is a pure shelf
/// handler, so tests drive it directly without opening a socket.
class EchoPinServer {
  EchoPinServer._({
    required this.config,
    required this.db,
    required this.keys,
    required this.audit,
    required this.auth,
    required this.telemetry,
    required this.admin,
    required this.backups,
    required this.retention,
    required this.handler,
  });

  final ServerConfig config;
  final Db db;
  final ServerKeys keys;
  final AuditLog audit;
  final AuthService auth;
  final TelemetryService telemetry;
  final AdminService admin;
  final BackupService backups;
  final RetentionService retention;
  final Handler handler;

  factory EchoPinServer.create({
    required ServerConfig config,
    required Db db,
    required ServerKeys keys,
    Mailer? mailer,
    PasswordHasher hasher = const PasswordHasher(),
    BreachChecker? breachChecker,
    Limiter? limiter,
    bool mailInBackground = true,
    Duration minPublicResponse = const Duration(milliseconds: 600),
    DateTime Function()? clock,
  }) {
    final AuditLog audit = AuditLog(macKey: keys.auditMacKey, clock: clock);
    // Rate limits live in PostgreSQL: they survive restarts and are shared
    // by every instance.
    final Limiter lim = limiter ?? DbRateLimiter(db, clock: clock);
    final Mailer mail = mailer ?? _defaultMailer(config);
    final CustodianKeys custodian = CustodianKeys(config.custodianPublicKeys);
    final AuthService auth = AuthService(
      db: db,
      keys: keys,
      mailer: mail,
      audit: audit,
      hasher: hasher,
      limiter: lim,
      breachChecker: breachChecker ??
          (config.passwordBreachCheck ? HibpBreachChecker() : const NoBreachChecker()),
      mailInBackground: mailInBackground,
      minPublicResponse: minPublicResponse,
      requireStaffTwoStep: config.requireStaffTwoStep,
      clock: clock,
    );
    final TelemetryService telemetry = TelemetryService(
      db: db,
      keys: keys,
      custodian: custodian,
      custodianRequired: config.custodianRequired,
      clock: clock,
    );
    final BackupService backups = BackupService(
      db: db,
      keys: keys,
      config: config,
      audit: audit,
      clock: clock,
    );
    final AdminService admin = AdminService(
      db: db,
      keys: keys,
      audit: audit,
      auth: auth,
      limiter: lim,
      mailer: mail,
      unsealAlerts: config.unsealAlerts,
      auditAnchor: backups.latestAnchor,
      clock: clock,
    );
    final RetentionService retention = RetentionService(
      db: db,
      config: config,
      audit: audit,
      clock: clock,
    );
    final Handler handler = const Pipeline()
        .addMiddleware(errorsAndLogging())
        .addMiddleware(securityHeaders())
        .addMiddleware(cors(config.corsOrigins))
        .addHandler(
          buildRouter(
            db: db,
            keys: keys,
            auth: auth,
            telemetry: telemetry,
            admin: admin,
            backups: backups,
            ipPolicy: ClientIpPolicy(
              trustProxy: config.trustProxy,
              header: config.clientIpHeader,
              proxyHops: config.proxyHops,
            ),
            custodian: custodian,
          ).call,
        );
    return EchoPinServer._(
      config: config,
      db: db,
      keys: keys,
      audit: audit,
      auth: auth,
      telemetry: telemetry,
      admin: admin,
      backups: backups,
      retention: retention,
      handler: handler,
    );
  }

  static Mailer _defaultMailer(ServerConfig c) => mailerFor(c.mail);
}
