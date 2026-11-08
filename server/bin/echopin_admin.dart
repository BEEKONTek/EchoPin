import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cryptography/cryptography.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:echopin_server/echopin_server.dart';

/// Operator tool. Everything destructive (restore) lives here on purpose,
/// not behind a button in the console.
Future<void> main(List<String> args) async {
  final CommandRunner<int> runner =
      CommandRunner<int>('echopin_admin', 'EchoPin server administration.')
        ..addCommand(_Migrate())
        ..addCommand(_InitKeys())
        ..addCommand(_RotateEscrow())
        ..addCommand(_ExportKeys())
        ..addCommand(_CreateAdmin())
        ..addCommand(_Backup())
        ..addCommand(_VerifyBackup())
        ..addCommand(_Restore())
        ..addCommand(_AuditVerify())
        ..addCommand(_InitCustodian());
  try {
    exit(await runner.run(args) ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on ConfigException catch (e) {
    stderr.writeln('Configuration error: $e');
    exit(64);
  } on KeysException catch (e) {
    stderr.writeln(e);
    exit(78);
  } on BackupException catch (e) {
    stderr.writeln('Backup error: $e');
    exit(1);
  } on ApiException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
}

ServerConfig get _config => ServerConfig.fromEnvironment();

Db _connect(ServerConfig c) => Db.connect(c.databaseUrl, poolSize: 2);

/// Keys for CLI work: ECHOPIN_KEYS, else KEYS_DIR (default `keys`).
Future<ServerKeys> _keys(ServerConfig c) {
  final String? bundle = c.keysBundle;
  if (bundle != null) return ServerKeys.fromBundle(bundle);
  return ServerKeys.load(c.keysDir ?? 'keys');
}

class _Migrate extends Command<int> {
  @override
  final String name = 'migrate';
  @override
  final String description = 'Apply pending database migrations.';

  @override
  Future<int> run() async {
    final Db db = _connect(_config);
    final List<int> ran = await migrate(db);
    stdout.writeln(ran.isEmpty ? 'Database is up to date.' : 'Applied $ran.');
    await db.close();
    return 0;
  }
}

class _InitKeys extends Command<int> {
  _InitKeys() {
    argParser.addFlag(
      'print-env',
      negatable: false,
      help: 'Print one ECHOPIN_KEYS secret instead of writing files (hosted).',
    );
  }

  @override
  final String name = 'init-keys';
  @override
  final String description = 'Create escrow, data and backup keys (new installs only).';

  @override
  Future<int> run() async {
    if (argResults!['print-env'] as bool) {
      stdout.writeln('ECHOPIN_KEYS=${await ServerKeys.newBundle()}');
      stderr.writeln(
        '\nStore the line above as a secret environment variable on your host,\n'
        'and keep a copy offline (a password manager is fine). Without it,\n'
        'sealed records, two-step sign-in and backups cannot be read.',
      );
      return 0;
    }
    final String dir = Platform.environment['KEYS_DIR'] ?? 'keys';
    await ServerKeys.create(dir);
    stdout.writeln(
      'Keys written to $dir.\n'
      'Copy this directory to offline storage now. Without it, sealed session '
      'logs, two-step sign-in and backups cannot be read.',
    );
    return 0;
  }
}

class _RotateEscrow extends Command<int> {
  @override
  final String name = 'rotate-escrow';
  @override
  final String description =
      'Add a new escrow key. Apps seal to it from their next config fetch; '
      'old keys stay so existing logs can still be opened.';

  @override
  Future<int> run() async {
    final String? bundle = Platform.environment['ECHOPIN_KEYS'];
    if (bundle != null && bundle.trim().isNotEmpty) {
      stdout.writeln('ECHOPIN_KEYS=${ServerKeys.rotateBundle(bundle)}');
      stderr.writeln('\nReplace the ECHOPIN_KEYS secret with the line above and redeploy.');
      return 0;
    }
    final String dir = Platform.environment['KEYS_DIR'] ?? 'keys';
    final String id = await ServerKeys.rotateEscrow(dir);
    stdout.writeln('New escrow key $id. Restart the server to start using it.');
    return 0;
  }
}

class _ExportKeys extends Command<int> {
  @override
  final String name = 'export-keys';
  @override
  final String description =
      'Print a keys directory as one ECHOPIN_KEYS secret (moving to hosting).';

  @override
  Future<int> run() async {
    final String dir = Platform.environment['KEYS_DIR'] ?? 'keys';
    stdout.writeln('ECHOPIN_KEYS=${ServerKeys.bundleFromDir(dir)}');
    return 0;
  }
}

class _CreateAdmin extends Command<int> {
  _CreateAdmin() {
    argParser
      ..addOption('email', mandatory: true)
      ..addOption('name', mandatory: true)
      ..addFlag('password-stdin', help: 'Read the password from stdin (for scripts).');
  }

  @override
  final String name = 'create-admin';
  @override
  final String description = 'Create an active admin account, or promote an existing one.';

  @override
  Future<int> run() async {
    final ArgResults a = argResults!;
    final String email = normalizeEmail(a['email'] as String);
    final String displayName = cleanDisplayName(a['name'] as String);
    final String password;
    if (a['password-stdin'] as bool) {
      password = (stdin.readLineSync() ?? '').trimRight();
    } else {
      stdout.write('Password for $email: ');
      stdin.echoMode = false;
      password = stdin.readLineSync() ?? '';
      stdin.echoMode = true;
      stdout.writeln();
    }
    final String? weak = passwordProblem(password, email: email);
    if (weak != null) {
      stderr.writeln(weak);
      return 1;
    }
    final Db db = _connect(_config);
    await migrate(db);
    final String hash = await const PasswordHasher().hash(password);
    final DateTime now = DateTime.now().toUtc();
    // The audit chain is keyed, so writing to it needs the server keys.
    final AuditLog audit = AuditLog(macKey: (await _keys(_config)).auditMacKey);
    await db.tx((DbSession tx) async {
      final Row row = (await tx.one(
        '''insert into accounts
             (email, email_normalized, display_name, password_hash, role, status,
              email_verified_at, created_at, updated_at)
           values (@e, @e, @n, @h, 'admin', 'active', @now, @now, @now)
           on conflict (email_normalized) do update
             set role = 'admin', status = 'active', password_hash = excluded.password_hash,
                 display_name = excluded.display_name,
                 email_verified_at = coalesce(accounts.email_verified_at, excluded.email_verified_at),
                 updated_at = excluded.updated_at
           returning id''',
        <String, Object?>{'e': email, 'n': displayName, 'h': hash, 'now': now},
      ))!;
      await audit.recordIn(
        tx,
        const AuditActor.system('cli'),
        'account.admin_created',
        target: row['id'] as String,
        detail: <String, Object?>{'email': email},
      );
    });
    await db.close();
    stdout.writeln('$email is an active admin.');
    return 0;
  }
}

Future<(Db, BackupService)> _backupService() async {
  final ServerConfig c = _config;
  final Db db = _connect(c);
  final ServerKeys keys = await _keys(c);
  return (db, BackupService(db: db, keys: keys, config: c, audit: AuditLog(macKey: keys.auditMacKey)));
}

class _Backup extends Command<int> {
  @override
  final String name = 'backup';
  @override
  final String description = 'Take an encrypted backup now.';

  @override
  Future<int> run() async {
    final (Db db, BackupService b) = await _backupService();
    final Map<String, Object?> r = await b.run(
      kind: 'manual',
      actor: const AuditActor.system('cli'),
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(r));
    await db.close();
    return 0;
  }
}

class _VerifyBackup extends Command<int> {
  @override
  final String name = 'verify-backup';
  @override
  final String description = 'Decrypt a backup and check that PostgreSQL can read it.';
  @override
  String get invocation => 'echopin_admin verify-backup <file or backup name>';

  @override
  Future<int> run() async {
    final List<String> rest = argResults!.rest;
    if (rest.length != 1) usageException('Give exactly one backup file.');
    final (Db db, BackupService b) = await _backupService();
    final int entries = await b.verifyFile(rest.single);
    stdout.writeln('OK: ${rest.single} decrypts and lists $entries database objects.');
    await db.close();
    return 0;
  }
}

class _Restore extends Command<int> {
  _Restore() {
    argParser
      ..addFlag('yes-overwrite-database',
          negatable: false, help: 'Required. Confirms you mean to replace all data.')
      ..addOption('database-url', help: 'Restore somewhere else (e.g. a scratch database).');
  }

  @override
  final String name = 'restore';
  @override
  final String description =
      'Replace the database with a backup. Stop the server first.';
  @override
  String get invocation =>
      'echopin_admin restore <file or backup name> --yes-overwrite-database';

  @override
  Future<int> run() async {
    final ArgResults a = argResults!;
    if (a.rest.length != 1) usageException('Give exactly one backup file.');
    if (!(a['yes-overwrite-database'] as bool)) {
      stderr.writeln(
        'Restoring replaces every account, report and log with the backup.\n'
        'Run `verify-backup` first, stop the server, then repeat with '
        '--yes-overwrite-database.',
      );
      return 1;
    }
    final (Db db, BackupService b) = await _backupService();
    await db.close();
    await b.restoreFile(a.rest.single, databaseUrl: a['database-url'] as String?);
    stdout.writeln('Restored ${a.rest.single}. Run `audit-verify`, then start the server.');
    return 0;
  }
}

class _AuditVerify extends Command<int> {
  @override
  final String name = 'audit-verify';
  @override
  final String description = 'Check the audit log hash chain end to end.';

  @override
  Future<int> run() async {
    final Db db = _connect(_config);
    final ServerKeys keys = await _keys(_config);
    final AuditVerification v = await AuditLog(macKey: keys.auditMacKey).verify(db);
    await db.close();
    if (v.ok) {
      stdout.writeln('Audit chain intact (${v.checked} entries).');
      return 0;
    }
    stderr.writeln('AUDIT CHAIN BROKEN at entry ${v.brokenAtId}: ${v.reason}');
    return 2;
  }
}

/// Creates a custodian key pair for double-sealed session records.
///
/// The public half goes into CUSTODIAN_PUBLIC_KEYS on the server; the
/// private half is imported into each responder's console (Console →
/// Custodian key) and kept offline. The server never sees it, which is the
/// point: with it in place, the server alone can't read any record.
class _InitCustodian extends Command<int> {
  @override
  final String name = 'init-custodian';
  @override
  final String description =
      'Create a custodian key: the server gets the public half, responders the private half.';

  @override
  Future<int> run() async {
    final SimpleKeyPair kp = await X25519().newKeyPair();
    final List<int> pub = (await kp.extractPublicKey()).bytes;
    final List<int> priv = await kp.extractPrivateKeyBytes();
    stdout
      ..writeln('1. On the server (Render → Environment), add or prepend:')
      ..writeln()
      ..writeln('   CUSTODIAN_PUBLIC_KEYS=${base64.encode(pub)}')
      ..writeln()
      ..writeln('2. Custodian key: import it in Console → Custodian key on every')
      ..writeln('   responder device that must open records, and keep a copy offline')
      ..writeln('   (password manager or printed in a safe). Never put it on the server.')
      ..writeln()
      ..writeln('   ECHOPIN-CUSTODIAN-1:${base64Url.encode(priv)}')
      ..writeln()
      ..writeln('   Key id: ${SealedBox.keyIdFor(pub)}')
      ..writeln()
      ..writeln('If every copy of this key is lost, double-sealed records can never be')
      ..writeln('opened again. If it leaks, create a new one, put it first in')
      ..writeln('CUSTODIAN_PUBLIC_KEYS, and import it on responder devices; old records')
      ..writeln('still need the old key.');
    return 0;
  }
}
