import 'dart:convert';
import 'dart:io';

/// SMTP settings (self-hosted). Hosted platforms often block SMTP ports;
/// use an HTTP mail API there instead ([MailConfig]).
class SmtpConfig {
  const SmtpConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.from,
    this.ssl = false,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String from;
  final bool ssl;
}

enum MailProvider { console, smtp, brevo, resend }

/// How verification and reset codes are emailed.
class MailConfig {
  const MailConfig({
    required this.provider,
    this.smtp,
    this.apiKey,
    this.from,
    this.fromName = 'EchoPin',
  });

  const MailConfig.console() : this(provider: MailProvider.console);

  final MailProvider provider;
  final SmtpConfig? smtp;

  /// Brevo or Resend API key.
  final String? apiKey;

  /// Sender address (must be verified with the provider).
  final String? from;
  final String fromName;
}

enum BackupStoreKind { local, supabase }

/// Where backup files go. Hosted containers have no lasting disk, so they
/// use object storage.
class BackupStoreConfig {
  const BackupStoreConfig.local() : kind = BackupStoreKind.local, supabaseUrl = null, supabaseKey = null, bucket = 'echopin-backups';
  const BackupStoreConfig.supabase({
    required String this.supabaseUrl,
    required String this.supabaseKey,
    this.bucket = 'echopin-backups',
  }) : kind = BackupStoreKind.supabase;

  final BackupStoreKind kind;
  final String? supabaseUrl;
  final String? supabaseKey;
  final String bucket;
}

/// Everything the server reads from its environment, validated once.
class ServerConfig {
  const ServerConfig({
    required this.databaseUrl,
    this.host = '0.0.0.0',
    this.port = 8080,
    this.keysBundle,
    this.keysDir,
    this.backupsDir = 'backups',
    this.devMode = false,
    this.trustProxy = false,
    this.clientIpHeader,
    this.proxyHops = 1,
    this.corsOrigins = const <String>[],
    this.mail = const MailConfig.console(),
    this.backupStore = const BackupStoreConfig.local(),
    this.backupHourUtc = 2,
    this.backupRetention = 14,
    this.backupsEnabled = true,
    this.databasePoolSize = 5,
    this.pgDump = 'pg_dump',
    this.pgRestore = 'pg_restore',
    this.requireStaffTwoStep = true,
    this.passwordBreachCheck = true,
    this.custodianPublicKeys = const <String>[],
    this.custodianRequired = false,
    this.unsealAlerts = true,
    this.retainSessionLogsDays = 365,
    this.retainDiagnosticsDays = 90,
    this.retainClosedReportsDays = 730,
  });

  /// `REQUIRE_STAFF_TWO_STEP` (default on): responders and admins must have
  /// two-step sign-in switched on before the console answers them. Their
  /// accounts can open emergency records, so a password alone is not
  /// enough.
  final bool requireStaffTwoStep;

  /// `PASSWORD_BREACH_CHECK` (default on): refuse passwords that appear in
  /// known breaches (Have I Been Pwned range API; only the first 5 hex
  /// characters of the password's SHA-1 leave the server).
  final bool passwordBreachCheck;

  /// `CUSTODIAN_PUBLIC_KEYS`: comma-separated base64 X25519 public keys,
  /// newest first. When set, apps seal session records twice: inside to
  /// the custodian key (held only on responders' devices), outside to the
  /// server's escrow key. The server alone can then no longer read them.
  final List<String> custodianPublicKeys;

  /// `CUSTODIAN_REQUIRED` (default: on when custodian keys are set): refuse
  /// uploads sealed only once.
  final bool custodianRequired;

  /// `UNSEAL_ALERTS` (default on): email every admin each time someone
  /// opens a session record.
  final bool unsealAlerts;

  /// `RETAIN_*_DAYS`: delete old data automatically (0 keeps it forever).
  /// The audit log is never deleted.
  final int retainSessionLogsDays;
  final int retainDiagnosticsDays;
  final int retainClosedReportsDays;

  /// libpq-style URL, e.g. `postgresql://echopin:pw@db:5432/echopin`.
  final String databaseUrl;
  final String host;
  final int port;

  /// `ECHOPIN_KEYS`: all keys as one secret (hosted deployments).
  final String? keysBundle;

  /// `KEYS_DIR`: keys as files on a lasting disk (self-hosted). When
  /// neither this nor [keysBundle] is set, the server refuses to start
  /// rather than create keys it would lose on the next restart.
  final String? keysDir;

  /// Local backups, and the staging area for remote ones.
  final String backupsDir;

  /// Prints verification codes to the log and allows creating keys on an
  /// existing database. Never set in production.
  final bool devMode;

  /// Read the client address from X-Forwarded-For (behind a reverse proxy
  /// or a platform router such as Render's).
  final bool trustProxy;

  /// `CLIENT_IP_HEADER`: a header the platform edge overwrites with the
  /// real client address (Render: `true-client-ip`). Used when
  /// [trustProxy] is on.
  final String? clientIpHeader;

  /// `TRUSTED_PROXY_HOPS`: proxies in front of the server that append to
  /// X-Forwarded-For. The client address is this many entries from the
  /// right; anything left of it was written by the client.
  final int proxyHops;

  /// Allowed browser origins for the web build. Native apps need none.
  final List<String> corsOrigins;
  final MailConfig mail;
  final BackupStoreConfig backupStore;

  /// Hour of day (UTC) for the scheduled backup.
  final int backupHourUtc;

  /// Number of successful backups to keep.
  final int backupRetention;
  final bool backupsEnabled;

  /// Connections this server keeps open. Free hosted databases allow few.
  final int databasePoolSize;
  final String pgDump;
  final String pgRestore;

  /// Back-compat for code written before [mail] existed.
  SmtpConfig? get smtp => mail.smtp;

  static ServerConfig fromEnvironment([Map<String, String>? env]) {
    final Map<String, String> e = env ?? Platform.environment;
    String? get(String k) {
      final String? v = e[k]?.trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    String need(String k, String why) =>
        get(k) ?? (throw ConfigException('$k is required $why'));

    final String? db = get('DATABASE_URL');
    if (db == null) {
      throw const ConfigException(
        'DATABASE_URL is not set, e.g. postgresql://echopin:pw@localhost:5432/echopin',
      );
    }
    int intOf(String k, int fallback, {int min = 0, int max = 1 << 30}) {
      final String? raw = get(k);
      if (raw == null) return fallback;
      final int? v = int.tryParse(raw);
      if (v == null || v < min || v > max) {
        throw ConfigException('$k must be a whole number from $min to $max');
      }
      return v;
    }

    bool boolOf(String k) =>
        const <String>{'1', 'true', 'yes'}.contains(get(k)?.toLowerCase());
    bool boolOr(String k, bool fallback) {
      final String? v = get(k)?.toLowerCase();
      if (v == null) return fallback;
      return const <String>{'1', 'true', 'yes'}.contains(v);
    }

    // SECURITY: refuse configurations that are only safe on a laptop.
    final bool dev = boolOf('ECHOPIN_DEV');
    final String dbHost = Uri.tryParse(db)?.host ?? '';
    if (dev && !const <String>{'localhost', '127.0.0.1', '::1', 'db', 'postgres'}.contains(dbHost)) {
      throw const ConfigException(
        'ECHOPIN_DEV is for local development only (it prints sign-in codes '
        'to the log). Remove it, or point DATABASE_URL at a local database',
      );
    }
    final List<String> origins = (get('CORS_ORIGINS') ?? '')
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (origins.contains('*') && !dev) {
      throw const ConfigException(
        'CORS_ORIGINS=* lets any website call this server from a browser. '
        'List the web console origin instead, e.g. https://console.example.org',
      );
    }
    // Public keys, so echoing a bad one in the error is fine. Each entry is
    // re-encoded canonically: hosts and copy-paste often drop the trailing
    // "=" padding, add quotes or the "CUSTODIAN_PUBLIC_KEYS=" prefix, or a
    // key may arrive in the URL-safe alphabet. None of that changes the key.
    String rawCustodian = (get('CUSTODIAN_PUBLIC_KEYS') ?? '').trim();
    if (rawCustodian.startsWith('CUSTODIAN_PUBLIC_KEYS=')) {
      rawCustodian = rawCustodian.substring('CUSTODIAN_PUBLIC_KEYS='.length);
    }
    final List<String> custodian = <String>[];
    for (final String entry in rawCustodian.split(',')) {
      final String k = entry.trim().replaceAll(RegExp('^["\']+|["\']+\$'), '').replaceAll(RegExp(r'\s+'), '');
      if (k.isEmpty) continue;
      List<int> bytes = const <int>[];
      try {
        bytes = base64.decode(base64.normalize(k));
      } catch (_) {}
      if (bytes.length != 32) {
        throw ConfigException(
          'CUSTODIAN_PUBLIC_KEYS has an entry that is not a 32-byte base64 key: "$k" '
          '(${bytes.isEmpty ? 'not base64' : '${bytes.length} bytes'}). Paste the value printed '
          'by `echopin_admin init-custodian` after "CUSTODIAN_PUBLIC_KEYS=".',
        );
      }
      custodian.add(base64.encode(bytes));
    }

    // Mail: explicit MAIL_PROVIDER, else SMTP when SMTP_HOST is set, else
    // the development console mailer.
    final String providerName =
        (get('MAIL_PROVIDER') ?? (get('SMTP_HOST') != null ? 'smtp' : 'console')).toLowerCase();
    final MailProvider provider = MailProvider.values.firstWhere(
      (MailProvider p) => p.name == providerName,
      orElse: () => throw ConfigException(
        'MAIL_PROVIDER must be one of console, smtp, brevo, resend (got "$providerName")',
      ),
    );
    final MailConfig mail = switch (provider) {
      MailProvider.console => const MailConfig.console(),
      MailProvider.smtp => MailConfig(
        provider: provider,
        smtp: SmtpConfig(
          host: need('SMTP_HOST', 'for MAIL_PROVIDER=smtp'),
          port: intOf('SMTP_PORT', 587, min: 1, max: 65535),
          username: get('SMTP_USERNAME') ?? '',
          password: get('SMTP_PASSWORD') ?? '',
          from: get('SMTP_FROM') ?? need('MAIL_FROM', 'for MAIL_PROVIDER=smtp'),
          ssl: boolOf('SMTP_SSL'),
        ),
      ),
      MailProvider.brevo => MailConfig(
        provider: provider,
        apiKey: need('BREVO_API_KEY', 'for MAIL_PROVIDER=brevo'),
        from: need('MAIL_FROM', 'for MAIL_PROVIDER=brevo (a sender verified in Brevo)'),
        fromName: get('MAIL_FROM_NAME') ?? 'EchoPin',
      ),
      MailProvider.resend => MailConfig(
        provider: provider,
        apiKey: need('RESEND_API_KEY', 'for MAIL_PROVIDER=resend'),
        from: need('MAIL_FROM', 'for MAIL_PROVIDER=resend (an address on a verified domain)'),
        fromName: get('MAIL_FROM_NAME') ?? 'EchoPin',
      ),
    };

    final String storeName = (get('BACKUP_STORE') ?? 'local').toLowerCase();
    final BackupStoreConfig store = switch (storeName) {
      'local' => const BackupStoreConfig.local(),
      'supabase' => BackupStoreConfig.supabase(
        supabaseUrl: need('SUPABASE_URL', 'for BACKUP_STORE=supabase'),
        supabaseKey: need('SUPABASE_SERVICE_KEY', 'for BACKUP_STORE=supabase (service role or secret key)'),
        bucket: get('SUPABASE_BACKUP_BUCKET') ?? 'echopin-backups',
      ),
      _ => throw ConfigException('BACKUP_STORE must be local or supabase (got "$storeName")'),
    };

    return ServerConfig(
      databaseUrl: db,
      host: get('HOST') ?? '0.0.0.0',
      port: intOf('PORT', 8080, min: 1, max: 65535),
      keysBundle: get('ECHOPIN_KEYS'),
      keysDir: get('KEYS_DIR'),
      backupsDir: get('BACKUPS_DIR') ?? (store.kind == BackupStoreKind.local ? 'backups' : Directory.systemTemp.path),
      devMode: dev,
      trustProxy: boolOf('TRUST_PROXY'),
      clientIpHeader: get('CLIENT_IP_HEADER')?.toLowerCase(),
      proxyHops: intOf('TRUSTED_PROXY_HOPS', 1, min: 1, max: 10),
      corsOrigins: origins,
      mail: mail,
      backupStore: store,
      backupHourUtc: intOf('BACKUP_HOUR_UTC', 2, max: 23),
      backupRetention: intOf('BACKUP_RETENTION', 14, min: 1, max: 365),
      backupsEnabled: !boolOf('BACKUPS_DISABLED'),
      databasePoolSize: intOf('DATABASE_POOL_SIZE', 5, min: 1, max: 100),
      pgDump: get('PG_DUMP') ?? 'pg_dump',
      pgRestore: get('PG_RESTORE') ?? 'pg_restore',
      requireStaffTwoStep: boolOr('REQUIRE_STAFF_TWO_STEP', true),
      passwordBreachCheck: boolOr('PASSWORD_BREACH_CHECK', true),
      custodianPublicKeys: custodian,
      custodianRequired: boolOr('CUSTODIAN_REQUIRED', custodian.isNotEmpty),
      unsealAlerts: boolOr('UNSEAL_ALERTS', true),
      retainSessionLogsDays: intOf('RETAIN_SESSION_LOGS_DAYS', 365, max: 36500),
      retainDiagnosticsDays: intOf('RETAIN_DIAGNOSTICS_DAYS', 90, max: 36500),
      retainClosedReportsDays: intOf('RETAIN_CLOSED_REPORTS_DAYS', 730, max: 36500),
    );
  }
}

class ConfigException implements Exception {
  const ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}
