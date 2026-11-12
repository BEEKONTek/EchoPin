// BACKUPS: encrypted database copies, on a schedule or on demand.
//
// Run:     pg_dump (EchoPin's tables only) -> encrypt in 1 MiB AES-GCM
//          frames -> upload to the store (local folder or Supabase
//          Storage) -> record in the `backups` table + audit log -> prune.
// Verify:  download -> decrypt every frame (any change or truncation
//          fails) -> compare SHA-256.
// Restore: verify -> pg_restore into the database, leaving Supabase's own
//          schemas alone.
// Only one backup runs at a time, enforced by a unique index in the
// database so it holds even with several server instances.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:logging/logging.dart';

import '../api/http.dart';
import '../config.dart';
import '../db/database.dart';
import '../security/audit.dart';
import '../security/keys.dart';
import 'backup_store.dart';

final Logger _log = Logger('backup');

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Encrypted, verifiable database backups.
///
/// A backup is `pg_dump --format=custom`, encrypted on the fly with the
/// backup key in 1 MiB frames (format below), written to a temp file and
/// renamed into place only when complete. Sealed session logs stay sealed
/// inside a backup: opening them still needs the escrow key, which is in
/// the keys directory and never in the dump.
///
/// File format `EPBK1`:
///
///     "EPBK" 0x01
///     frame*: flags(1) | length(4, BE) | nonce(12) | ciphertext+mac(length)
///
/// Each frame is AES-256-GCM with associated data
/// `"EPBK1" ‖ frameIndex(8, BE) ‖ flags`. Exactly the last frame carries
/// flag 0x01, so reordering, dropping or truncating frames fails to
/// decrypt instead of producing a silently shorter database.
class BackupService {
  BackupService({
    required Db db,
    required ServerKeys keys,
    required ServerConfig config,
    required AuditLog audit,
    BackupStore? store,
    DateTime Function()? clock,
  }) : _db = db,
       _keys = keys,
       _config = config,
       _audit = audit,
       _store = store ?? backupStoreFor(config),
       _clock = clock ?? DateTime.now;

  final Db _db;
  final ServerKeys _keys;
  final ServerConfig _config;
  final AuditLog _audit;
  final BackupStore _store;
  final DateTime Function() _clock;
  Timer? _timer;
  bool _running = false;

  static const List<int> magic = <int>[0x45, 0x50, 0x42, 0x4b, 0x01]; // EPBK1
  static const int frameSize = 1 << 20;
  static final AesGcm _aes = AesGcm.with256bits();

  bool get isRunning => _running;
  BackupStore get store => _store;

  // ── Scheduling ─────────────────────────────────────────────────────────

  void startSchedule() {
    if (!_config.backupsEnabled) {
      _log.warning('Scheduled backups are disabled (BACKUPS_DISABLED)');
      return;
    }
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(_tick()),
    );
    unawaited(() async {
      // A backup that was running when its server died never finishes;
      // free the slot so the next one can start. This must not depend on
      // the store being reachable, or one bad setting blocks backups forever.
      try {
        await _db.execute(
          '''update backups set status = 'failed', error = 'interrupted (server restarted)',
               finished_at = @now
             where status = 'running' and started_at < @cutoff''',
          <String, Object?>{
            'now': _clock().toUtc(),
            'cutoff': _clock().toUtc().subtract(const Duration(hours: 2)),
          },
        );
      } catch (e) {
        _log.severe('Could not clear interrupted backups: $e');
      }
      try {
        await _store.ensureReady();
        _log.info('Backups go to ${_store.description}');
      } catch (e) {
        // Logged here; the backup run below repeats the check and records
        // the reason in the backups list, where the console shows it.
        _log.severe('Backup store is not ready: $e');
      }
      await _tick();
    }());
  }

  void stop() => _timer?.cancel();

  Future<void> _tick() async {
    if (_running) return;
    try {
      final DateTime now = _clock().toUtc();
      final Row? last = await _db.one(
        "select started_at from backups where status = 'ok' order by started_at desc limit 1",
      );
      final DateTime? lastAt = last?['started_at'] as DateTime?;
      final bool due = lastAt == null
          ? true
          : now.difference(lastAt) >= const Duration(hours: 20) &&
                now.hour == _config.backupHourUtc;
      // Overdue by more than two days (server was down at backup time):
      // run now instead of waiting for the hour.
      final bool overdue =
          lastAt != null && now.difference(lastAt) > const Duration(hours: 48);
      if (due || overdue) {
        await run(kind: 'scheduled', actor: const AuditActor.system('backup'));
      }
    } catch (e, st) {
      _log.severe('Scheduled backup failed', e, st);
    }
  }

  // ── Run ────────────────────────────────────────────────────────────────

  Future<Map<String, Object?>> run({
    required String kind,
    required AuditActor actor,
  }) async {
    if (_running) {
      throw const ApiException(
        409,
        'backup_running',
        'A backup is already running',
      );
    }
    _running = true;
    final DateTime started = _clock().toUtc();
    final Row row;
    try {
      // A partial unique index allows one running backup across every
      // server instance sharing this database.
      row = (await _db.one(
        '''insert into backups (kind, status, created_by, started_at)
           values (@k, 'running', @by::uuid, @at) returning id''',
        <String, Object?>{'k': kind, 'by': actor.id, 'at': started},
      ))!;
    } catch (e) {
      _running = false;
      if ('$e'.contains('backups_one_running')) {
        throw const ApiException(
          409,
          'backup_running',
          'A backup is already running',
        );
      }
      rethrow;
    }
    final String id = row['id'] as String;
    final Directory dir = await Directory.systemTemp.createTemp(
      'echopin-backup-',
    );
    final String stamp = started
        .toIso8601String()
        .replaceAll(RegExp(r'[:\-]'), '')
        .replaceAll(RegExp(r'\.\d+Z$'), 'Z');
    final String name = 'echopin-$stamp.epbk';
    final File part = File('${dir.path}/$name.part');
    try {
      // Checked on every run (one cheap request a day) so a store problem
      // lands in this backup's error, visible in Console → Backups, rather
      // than only in the host's log.
      await _store.ensureReady();
      final (String dbArg, Map<String, String> env) = libpqTarget(
        _config.databaseUrl,
      );
      final Process p = await Process.start(_config.pgDump, <String>[
        '--format=custom',
        '--no-owner',
        '--no-privileges',
        // Only EchoPin's tables. Hosted Postgres (Supabase) keeps its own
        // schemas in the same database; those are not ours to back up
        // or to drop on restore.
        '--schema=public',
        '--dbname=$dbArg',
      ], environment: env);
      final Future<String> stderr = p.stderr.transform(utf8.decoder).join();
      final IOSink sink = part.openWrite();
      final String sha;
      try {
        sha = await encryptStream(p.stdout, sink, _keys.backupKey);
      } finally {
        await sink.close();
      }
      final int code = await p.exitCode;
      if (code != 0) {
        throw BackupException(
          'pg_dump exited with $code: ${(await stderr).trim()}',
        );
      }
      final int size = await part.length();
      await _store.put(name, part);
      await _db.tx((DbSession tx) async {
        await tx.execute(
          '''update backups set status = 'ok', file_name = @f, size_bytes = @s,
               sha256 = @h, finished_at = @at where id = @id::uuid''',
          <String, Object?>{
            'f': name,
            's': size,
            'h': sha,
            'at': _clock().toUtc(),
            'id': id,
          },
        );
        await _audit.recordIn(
          tx,
          actor,
          'backup.created',
          target: id,
          detail: <String, Object?>{'file': name, 'bytes': size, 'kind': kind},
        );
      });
      _log.info('Backup $name stored in ${_store.description} ($size bytes)');
      // Write the audit chain's tip to the platform log, which lives
      // outside the database. A keyed chain can't be forged, but someone
      // with database access could still cut rows off the *end*. Comparing
      // today's tip with the one logged here shows whether that happened.
      final Row? tip = await _db.one(
        'select id, encode(hash, \'hex\') as hash from audit_log order by id desc limit 1',
      );
      if (tip != null) {
        _log.info('Audit chain tip: entry ${tip['id']} hash ${tip['hash']}');
        // ...and next to the backups, where Check chain compares against it
        // automatically (see latestAnchor). Best effort: a failed anchor
        // write never fails the backup.
        try {
          final File anchor = File('${dir.path}/audit-anchor.json')
            ..writeAsStringSync(
              jsonEncode(<String, Object?>{
                'id': tip['id'],
                'hash': tip['hash'],
                'at': _clock().toUtc().toIso8601String(),
              }),
            );
          await _store.put(anchorName, anchor);
        } catch (e) {
          _log.warning('Could not store the audit anchor: $e');
        }
      }
      await _prune();
      return <String, Object?>{
        'id': id,
        'fileName': name,
        'sizeBytes': size,
        'sha256': sha,
      };
    } catch (e) {
      final String message = e is ProcessException
          ? '${_config.pgDump} not found. Install the PostgreSQL client tools'
          : '$e';
      await _db.execute(
        '''update backups set status = 'failed', error = @e, finished_at = @at
           where id = @id::uuid''',
        <String, Object?>{'e': message, 'at': _clock().toUtc(), 'id': id},
      );
      await _audit.record(
        _db,
        actor,
        'backup.failed',
        target: id,
        detail: <String, Object?>{'error': message},
      );
      throw ApiException(500, 'backup_failed', 'The backup failed: $message');
    } finally {
      _running = false;
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _prune() async {
    final List<Row> old = await _db.query(
      '''select id, file_name from backups where status = 'ok'
          order by started_at desc offset @keep''',
      <String, Object?>{'keep': _config.backupRetention},
    );
    for (final Row r in old) {
      try {
        await _store.delete(r['file_name'] as String);
      } catch (e) {
        _log.warning('Could not remove old backup ${r['file_name']}: $e');
        continue;
      }
      await _db.execute(
        "update backups set status = 'pruned' where id = @id::uuid",
        <String, Object?>{'id': r['id']},
      );
    }
  }

  /// Name of the small object holding the newest audit chain tip.
  static const String anchorName = 'audit-anchor.json';

  /// The audit chain tip recorded with the newest backup, or null.
  ///
  /// The database can't vouch for itself: someone able to delete rows from
  /// the end of the audit log could delete the evidence too. This copy
  /// lives in the backup store instead. If the live chain no longer
  /// contains this entry with this hash, rows were removed.
  Future<({int id, String hash})?> latestAnchor() async {
    final Directory tmp = await Directory.systemTemp.createTemp('anchor');
    try {
      final File f = File('${tmp.path}/a.json');
      await _store.fetch(anchorName, f);
      final Map<String, dynamic> j =
          jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return (id: j['id'] as int, hash: j['hash'] as String);
    } catch (_) {
      return null; // no backup yet, or store unreachable
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  Future<List<Map<String, Object?>>> list() async {
    final List<Row> rows = await _db.query(
      '''select b.id, b.kind, b.status, b.file_name, b.size_bytes, b.sha256, b.error,
                b.started_at, b.finished_at, a.email as created_by
           from backups b left join accounts a on a.id = b.created_by
          order by b.started_at desc limit 60''',
    );
    return rows
        .map(
          (Row r) => <String, Object?>{
            'id': r['id'],
            'kind': r['kind'],
            'status': r['status'],
            'fileName': r['file_name'],
            'sizeBytes': r['size_bytes'],
            'sha256': r['sha256'],
            'error': r['error'],
            'startedAt': r['started_at'],
            'finishedAt': r['finished_at'],
            'createdBy': r['created_by'],
            // True/false for local disk; null (unknown) for object storage.
            'onDisk': r['file_name'] == null
                ? false
                : _store.existsCheap(r['file_name'] as String),
          },
        )
        .toList();
  }

  // ── Verify and restore (command line only) ─────────────────────────────

  /// Decrypts a backup fully and asks pg_restore to read its table of
  /// contents. [file] is a local path or a backup name in the store.
  /// Throws [BackupException] describing any problem.
  Future<int> verifyFile(String file) async {
    final File tmp = await _decryptToTemp(file);
    try {
      final ProcessResult r = await Process.run(_config.pgRestore, <String>[
        '--list',
        tmp.path,
      ]);
      if (r.exitCode != 0) {
        throw BackupException(
          'pg_restore could not read the dump: ${r.stderr}',
        );
      }
      return '${r.stdout}'
          .split('\n')
          .where((String l) => l.isNotEmpty && !l.startsWith(';'))
          .length;
    } finally {
      if (tmp.parent.existsSync()) tmp.parent.deleteSync(recursive: true);
    }
  }

  /// Replaces the contents of [databaseUrl] (default: the configured
  /// database) with [file]. Destructive; the CLI asks for confirmation.
  Future<void> restoreFile(String file, {String? databaseUrl}) async {
    final File tmp = await _decryptToTemp(file);
    try {
      final (String dbArg, Map<String, String> env) = libpqTarget(
        databaseUrl ?? _config.databaseUrl,
      );
      // Restore everything except the public schema itself: dropping and
      // recreating `public` would take hosted databases' own grants and
      // objects with it.
      final ProcessResult listed = await Process.run(
        _config.pgRestore,
        <String>['--list', tmp.path],
      );
      if (listed.exitCode != 0) {
        throw BackupException(
          'pg_restore could not read the dump: ${listed.stderr}',
        );
      }
      final File toc = File('${tmp.path}.list')
        ..writeAsStringSync(restoreList('${listed.stdout}'));
      final ProcessResult r = await Process.run(_config.pgRestore, <String>[
        '-L',
        toc.path,
        '--clean',
        '--if-exists',
        '--no-owner',
        '--no-privileges',
        '--single-transaction',
        '--exit-on-error',
        '--dbname=$dbArg',
        tmp.path,
      ], environment: env);
      toc.deleteSync();
      if (r.exitCode != 0) {
        throw BackupException('pg_restore failed: ${r.stderr}');
      }
    } finally {
      if (tmp.parent.existsSync()) tmp.parent.deleteSync(recursive: true);
    }
  }

  /// [toc] (pg_restore --list output) without the public schema's own
  /// entries.
  static String restoreList(String toc) => toc
      .split('\n')
      .where(
        (String l) => !RegExp(
          r'^\d+; \d+ \d+ (SCHEMA - public|COMMENT - SCHEMA public) ',
        ).hasMatch(l),
      )
      .join('\n');

  Future<File> _decryptToTemp(String file) async {
    final Directory work = await Directory.systemTemp.createTemp(
      'echopin-restore-',
    );
    File src = File(file);
    if (!src.existsSync()) {
      // Not a local path: fetch it from the store by name.
      final File fetched = File('${work.path}/download.epbk');
      try {
        await _store.fetch(file, fetched);
      } on StoreException catch (e) {
        throw BackupException('$e');
      }
      src = fetched;
    }
    final File tmp = File('${work.path}/restore.dump');
    final IOSink sink = tmp.openWrite();
    try {
      await decryptStream(src.openRead(), sink, _keys.backupKey);
    } catch (e) {
      await sink.close();
      if (work.existsSync()) work.deleteSync(recursive: true);
      rethrow;
    }
    await sink.close();
    return tmp;
  }

  // ── Format ─────────────────────────────────────────────────────────────

  /// Encrypts [input] into [out]; returns the SHA-256 (hex) of the output.
  static Future<String> encryptStream(
    Stream<List<int>> input,
    IOSink out,
    SecretKey key,
  ) async {
    final _DigestSink digest = _DigestSink();
    final ByteConversionSink hasher = crypto.sha256.startChunkedConversion(
      digest,
    );
    void write(List<int> bytes) {
      out.add(bytes);
      hasher.add(bytes);
    }

    write(magic);
    final BytesBuilder buf = BytesBuilder(copy: false);
    int index = 0;
    Future<void> frame(List<int> clear, bool last) async {
      final int flags = last ? 1 : 0;
      final SecretBox box = await _aes.encrypt(
        clear,
        secretKey: key,
        aad: _aad(index, flags),
      );
      final ByteData len = ByteData(4)
        ..setUint32(0, box.cipherText.length + 16);
      write(<int>[flags]);
      write(len.buffer.asUint8List());
      write(box.nonce);
      write(box.cipherText);
      write(box.mac.bytes);
      index++;
    }

    await for (final List<int> chunk in input) {
      buf.add(chunk);
      while (buf.length >= frameSize) {
        final Uint8List all = buf.takeBytes();
        await frame(Uint8List.sublistView(all, 0, frameSize), false);
        if (all.length > frameSize) {
          buf.add(Uint8List.sublistView(all, frameSize));
        }
      }
    }
    await frame(buf.takeBytes(), true);
    hasher.close();
    return digest.value.toString();
  }

  static Future<void> decryptStream(
    Stream<List<int>> input,
    IOSink out,
    SecretKey key,
  ) async {
    final _Reader r = _Reader(input);
    final List<int> head = await r.take(magic.length);
    for (int i = 0; i < magic.length; i++) {
      if (head.length != magic.length || head[i] != magic[i]) {
        throw const BackupException('Not an EchoPin backup (bad header)');
      }
    }
    int index = 0;
    bool sawLast = false;
    while (true) {
      final List<int> flagsByte = await r.take(1);
      if (flagsByte.isEmpty) break;
      if (sawLast) throw const BackupException('Data after the final frame');
      final int flags = flagsByte[0];
      final List<int> lenBytes = await r.take(4);
      if (lenBytes.length != 4) {
        throw const BackupException('Backup is truncated');
      }
      final int len = ByteData.sublistView(
        Uint8List.fromList(lenBytes),
      ).getUint32(0);
      if (len < 16 || len > frameSize + 16) {
        throw const BackupException('Backup is corrupt (bad frame length)');
      }
      final List<int> nonce = await r.take(12);
      final List<int> body = await r.take(len);
      if (nonce.length != 12 || body.length != len) {
        throw const BackupException('Backup is truncated');
      }
      try {
        final List<int> clear = await _aes.decrypt(
          SecretBox(
            body.sublist(0, len - 16),
            nonce: nonce,
            mac: Mac(body.sublist(len - 16)),
          ),
          secretKey: key,
          aad: _aad(index, flags),
        );
        out.add(clear);
      } on SecretBoxAuthenticationError {
        throw const BackupException(
          'Backup failed its integrity check: wrong backup key, or the file '
          'was altered',
        );
      }
      sawLast = flags & 1 == 1;
      index++;
    }
    if (!sawLast) {
      throw const BackupException('Backup is truncated (no final frame)');
    }
  }

  static List<int> _aad(int index, int flags) {
    final ByteData b = ByteData(8)..setUint64(0, index);
    return <int>[...magic, ...b.buffer.asUint8List(), flags];
  }
}

/// Splits a libpq URL into a password-free `--dbname` argument and a
/// `PGPASSWORD` environment entry, so the password never shows up in the
/// process list.
(String, Map<String, String>) libpqTarget(String url) {
  final Uri u = Uri.parse(url);
  final List<String> info = u.userInfo.split(':');
  final String user = Uri.decodeComponent(info.first);
  final String? password = info.length > 1
      ? Uri.decodeComponent(info.sublist(1).join(':'))
      : null;
  final Uri clean = u.replace(userInfo: user);
  return (
    clean.toString(),
    <String, String>{
      if (password != null && password.isNotEmpty) 'PGPASSWORD': password,
    },
  );
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// Pulls exact byte counts out of a chunked stream.
class _Reader {
  _Reader(Stream<List<int>> s) : _it = StreamIterator<List<int>>(s);
  final StreamIterator<List<int>> _it;
  final BytesBuilder _buf = BytesBuilder(copy: false);

  Future<List<int>> take(int n) async {
    while (_buf.length < n) {
      if (!await _it.moveNext()) break;
      _buf.add(_it.current);
    }
    final Uint8List all = _buf.takeBytes();
    if (all.length <= n) return all;
    _buf.add(Uint8List.sublistView(all, n));
    return Uint8List.sublistView(all, 0, n);
  }
}
