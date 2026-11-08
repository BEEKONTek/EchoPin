import 'package:logging/logging.dart';

import 'database.dart';

final Logger _log = Logger('migrations');

class Migration {
  const Migration(this.version, this.name, this.sql);
  final int version;
  final String name;
  final String sql;
}

/// Ordered, append-only schema history. Never edit a shipped migration;
/// add a new one.
const List<Migration> migrations = <Migration>[
  Migration(1, 'accounts_and_auth', r'''
create table accounts (
  id                uuid primary key default gen_random_uuid(),
  email             text not null,
  email_normalized  text not null unique,
  display_name      text not null,
  password_hash     text not null,
  role              text not null default 'member'
                    check (role in ('member', 'responder', 'admin')),
  status            text not null default 'pending'
                    check (status in ('pending', 'active', 'disabled')),
  email_verified_at timestamptz,
  totp_secret_enc   bytea,
  totp_pending_enc  bytea,
  totp_last_step    bigint,
  failed_logins     int not null default 0,
  locked_until      timestamptz,
  created_at        timestamptz not null,
  updated_at        timestamptz not null,
  last_login_at     timestamptz
);
create index accounts_role_idx on accounts (role) where role <> 'member';

create table email_codes (
  id          bigserial primary key,
  account_id  uuid not null references accounts (id) on delete cascade,
  purpose     text not null check (purpose in ('verify', 'reset')),
  code_hash   bytea not null,
  attempts    int not null default 0,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null
);
create index email_codes_lookup_idx on email_codes (account_id, purpose, created_at desc);

-- One row per install. The public key is an Ed25519 key that never leaves
-- the device's keystore; every token refresh must be signed by it.
create table devices (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references accounts (id) on delete cascade,
  public_key    bytea not null check (length(public_key) = 32),
  label         text not null,
  platform      text not null,
  app_version   text,
  created_at    timestamptz not null,
  last_seen_at  timestamptz not null,
  revoked_at    timestamptz,
  unique (account_id, public_key)
);

-- Token pairs. Rotating a refresh token links the old row to the new one;
-- presenting an already-rotated refresh token revokes the whole family.
create table auth_sessions (
  id                  uuid primary key default gen_random_uuid(),
  account_id          uuid not null references accounts (id) on delete cascade,
  device_id           uuid not null references devices (id) on delete cascade,
  family              uuid not null,
  access_hash         bytea not null unique,
  refresh_hash        bytea not null unique,
  access_expires_at   timestamptz not null,
  refresh_expires_at  timestamptz not null,
  created_at          timestamptz not null,
  replaced_by         uuid,
  revoked_at          timestamptz,
  revoked_reason      text
);
create index auth_sessions_family_idx on auth_sessions (family);
create index auth_sessions_account_idx on auth_sessions (account_id) where revoked_at is null;
'''),
  Migration(2, 'telemetry_and_reports', r'''
create table diagnostics (
  id           bigserial primary key,
  account_id   uuid references accounts (id) on delete set null,
  device_id    uuid references devices (id) on delete set null,
  level        text not null check (level in ('info', 'warning', 'error')),
  app_version  text not null,
  platform     text not null,
  summary      text not null,
  payload      jsonb not null,
  received_at  timestamptz not null
);
create index diagnostics_received_idx on diagnostics (received_at desc);
create index diagnostics_level_idx on diagnostics (level, received_at desc) where level <> 'info';

-- Each member's device uploads its own view of a session. The event log is
-- sealed to the escrow key; only the metadata columns are readable without
-- break-glass.
create table session_logs (
  id              uuid primary key,
  session_id      text not null,
  session_name    text not null,
  account_id      uuid references accounts (id) on delete set null,
  device_id       uuid references devices (id) on delete set null,
  started_at      timestamptz not null,
  ended_at        timestamptz,
  member_count    int not null default 0,
  sos_count       int not null default 0,
  checkin_count   int not null default 0,
  help_count      int not null default 0,
  crossing_count  int not null default 0,
  end_reason      text,
  key_id          text not null,
  sealed          bytea not null,
  received_at     timestamptz not null
);
create index session_logs_session_idx on session_logs (session_id);
create index session_logs_started_idx on session_logs (started_at desc);
create index session_logs_account_idx on session_logs (account_id, started_at desc);

create table unseal_grants (
  id              uuid primary key default gen_random_uuid(),
  session_log_id  uuid not null references session_logs (id) on delete cascade,
  account_id      uuid not null references accounts (id),
  reason          text not null,
  case_ref        text,
  created_at      timestamptz not null
);
create index unseal_grants_log_idx on unseal_grants (session_log_id);

create table reports (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid references accounts (id) on delete set null,
  device_id     uuid references devices (id) on delete set null,
  category      text not null check (category in ('bug', 'safety', 'abuse', 'account', 'other')),
  severity      text not null check (severity in ('low', 'normal', 'high', 'critical')),
  status        text not null default 'open'
                check (status in ('open', 'investigating', 'resolved', 'dismissed')),
  subject       text not null,
  body          text not null,
  session_id    text,
  diagnostics   jsonb,
  assignee_id   uuid references accounts (id) on delete set null,
  resolution    text,
  created_at    timestamptz not null,
  updated_at    timestamptz not null
);
create index reports_status_idx on reports (status, severity, created_at desc);
create index reports_account_idx on reports (account_id, created_at desc);

create table report_notes (
  id          bigserial primary key,
  report_id   uuid not null references reports (id) on delete cascade,
  author_id   uuid references accounts (id) on delete set null,
  body        text not null,
  created_at  timestamptz not null
);
create index report_notes_report_idx on report_notes (report_id, created_at);
'''),
  Migration(3, 'audit_and_backups', r'''
-- Append-only, hash-chained. Each row's hash covers the previous row's
-- hash, so deleting or editing history breaks verification from that row
-- on. The triggers refuse UPDATE, DELETE and TRUNCATE outright.
create table audit_log (
  id           bigserial primary key,
  at           timestamptz not null,
  actor_id     uuid,
  actor_label  text not null,
  action       text not null,
  target       text,
  detail       text not null,
  ip           text,
  prev_hash    bytea not null,
  hash         bytea not null
);
create index audit_log_action_idx on audit_log (action, id desc);
create index audit_log_actor_idx on audit_log (actor_id, id desc);

create function audit_log_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'audit_log is append-only';
end $$;
create trigger audit_log_no_change before update or delete on audit_log
  for each row execute function audit_log_immutable();
create trigger audit_log_no_truncate before truncate on audit_log
  for each statement execute function audit_log_immutable();

create table backups (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('scheduled', 'manual')),
  status       text not null check (status in ('running', 'ok', 'failed', 'pruned')),
  file_name    text,
  size_bytes   bigint,
  sha256       text,
  error        text,
  created_by   uuid references accounts (id) on delete set null,
  started_at   timestamptz not null,
  finished_at  timestamptz
);
create index backups_started_idx on backups (started_at desc);
'''),
  Migration(4, 'session_log_checkpoints', r'''
-- Devices upload checkpoints during a session (immediately after an SOS)
-- and a final log at the end. Each upload is a complete sealed snapshot;
-- the index uses the newest upload per device.
alter table session_logs add column sequence int not null default 0;
alter table session_logs add column is_final boolean not null default true;
create index session_logs_latest_idx on session_logs (session_id, device_id, sequence desc);
'''),
  Migration(5, 'one_running_backup', r'''
-- Several server instances can share one database (hosted platforms
-- restart and scale them freely). At most one backup runs at a time.
create unique index backups_one_running on backups ((true)) where status = 'running';
'''),
  Migration(6, 'hardening', r'''
-- Rate limits in the database: they survive restarts (free hosts restart
-- often) and are shared by every server instance. Fixed windows per key.
create table rate_hits (
  key           text primary key,
  window_start  timestamptz not null,
  hits          int not null
);

-- Sign-in failures per *email*, whether or not an account exists, so a
-- "locked" answer can't reveal that an address is registered.
create table login_throttle (
  email         text primary key,
  failures      int not null default 0,
  locked_until  timestamptz,
  updated_at    timestamptz not null
);

-- Second seal (custodian key held off the server) and the session tag
-- that shows an upload came from someone who knew the session key.
alter table session_logs add column custodian_key_id text;
alter table session_logs add column session_tag bytea;

-- Devices that could not keep their key in an OS keystore get shorter
-- refresh tokens; the console shows which ones.
alter table devices add column secure_storage boolean not null default true;
'''),
];

/// Applies pending [migrations] under an advisory lock, so two server
/// instances starting together cannot race.
Future<List<int>> migrate(Db db) {
  return db.tx((DbSession tx) async {
    await tx.execute('select pg_advisory_xact_lock(727274)');
    await tx.execute('''
      create table if not exists schema_migrations (
        version     int primary key,
        name        text not null,
        applied_at  timestamptz not null default now()
      )''');
    final Set<int> applied = (await tx.query(
      'select version from schema_migrations',
    )).map((Row r) => r['version'] as int).toSet();
    final List<int> ran = <int>[];
    for (final Migration m in migrations) {
      if (applied.contains(m.version)) continue;
      _log.info('Applying migration ${m.version} ${m.name}');
      for (final String statement in splitStatements(m.sql)) {
        await tx.execute(statement);
      }
      await tx.execute(
        'insert into schema_migrations (version, name) values (@v, @n)',
        <String, Object?>{'v': m.version, 'n': m.name},
      );
      ran.add(m.version);
    }
    return ran;
  });
}

/// True when the database has never been migrated (a fresh install).
Future<bool> isFreshDatabase(Db db) async {
  final Row? r = await db.one(
    "select to_regclass('public.schema_migrations') is null as fresh",
  );
  return r!['fresh'] as bool;
}

/// Splits a migration on top-level semicolons, keeping `$$ … $$` bodies
/// and `--` comments intact. The extended protocol runs one statement per
/// call.
List<String> splitStatements(String sql) {
  final List<String> out = <String>[];
  final StringBuffer cur = StringBuffer();
  bool inDollar = false;
  bool inComment = false;
  for (int i = 0; i < sql.length; i++) {
    final String c = sql[i];
    if (inComment) {
      cur.write(c);
      if (c == '\n') inComment = false;
      continue;
    }
    if (!inDollar && c == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      inComment = true;
      cur.write(c);
      continue;
    }
    if (c == r'$' && i + 1 < sql.length && sql[i + 1] == r'$') {
      inDollar = !inDollar;
      cur.write(r'$$');
      i++;
      continue;
    }
    if (c == ';' && !inDollar) {
      final String s = _stripComments(cur.toString()).trim();
      if (s.isNotEmpty) out.add(cur.toString().trim());
      cur.clear();
      continue;
    }
    cur.write(c);
  }
  final String tail = _stripComments(cur.toString()).trim();
  if (tail.isNotEmpty) out.add(cur.toString().trim());
  return out;
}

String _stripComments(String s) =>
    s.split('\n').where((String l) => !l.trimLeft().startsWith('--')).join('\n');
