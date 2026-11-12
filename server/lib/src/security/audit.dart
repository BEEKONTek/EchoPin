import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../db/database.dart';

/// Result of walking the audit chain.
class AuditVerification {
  const AuditVerification({
    required this.ok,
    required this.checked,
    this.brokenAtId,
    this.reason,
  });

  final bool ok;
  final int checked;
  final int? brokenAtId;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'checked': checked,
    'brokenAtId': brokenAtId,
    'reason': reason,
  };
}

/// Who did something. System jobs use [AuditActor.system].
class AuditActor {
  const AuditActor({this.id, required this.label, this.ip});
  const AuditActor.system(String job)
    : id = null,
      label = 'system:$job',
      ip = null;

  final String? id;
  final String label;
  final String? ip;
}

/// Append-only, hash-chained record of every privileged action.
///
/// Each row stores `hash = HMAC-SHA256(key, previous hash ‖ canonical row)`.
/// Three layers protect it:
///
/// 1. The database refuses UPDATE / DELETE / TRUNCATE on the table
///    (triggers in migration 3).
/// 2. Every row's hash covers the row before it, so changing, inserting or
///    removing any row breaks every hash after it.
/// 3. The hash is keyed with [ServerKeys.auditMacKey], which lives in
///    ECHOPIN_KEYS and never in the database. Someone with full database
///    access can drop the triggers and edit rows, but cannot recompute
///    valid hashes, so [verify] catches them from the first altered row.
///
/// Limit: deleting rows from the *end* of the chain leaves a shorter chain
/// that still verifies. The server logs the chain tip with every scheduled
/// backup, which gives an outside reference to compare against.
class AuditLog {
  AuditLog({required List<int> macKey, DateTime Function()? clock})
    : _mac = crypto.Hmac(crypto.sha256, macKey),
      _clock = clock ?? DateTime.now;

  final crypto.Hmac _mac;
  final DateTime Function() _clock;
  static final Uint8List genesis = Uint8List(32);

  /// Records in its own transaction.
  Future<void> record(
    Db db,
    AuditActor actor,
    String action, {
    String? target,
    Map<String, Object?> detail = const <String, Object?>{},
  }) => db.tx(
    (DbSession tx) =>
        recordIn(tx, actor, action, target: target, detail: detail),
  );

  /// Records inside the caller's transaction, so the audit row commits or
  /// rolls back together with the action it describes.
  Future<void> recordIn(
    DbSession tx,
    AuditActor actor,
    String action, {
    String? target,
    Map<String, Object?> detail = const <String, Object?>{},
  }) async {
    // Serialises writers so the chain has exactly one tip.
    await tx.execute('select pg_advisory_xact_lock(727275)');
    final Row? tip = await tx.one(
      'select hash from audit_log order by id desc limit 1',
    );
    final List<int> prev = tip == null ? genesis : tip['hash'] as List<int>;
    final DateTime at = _truncate(_clock().toUtc());
    final String detailJson = canonicalJson(detail);
    final Uint8List hash = _hash(
      prev,
      at,
      actor.id,
      actor.label,
      action,
      target,
      detailJson,
      actor.ip,
    );
    await tx.execute(
      '''insert into audit_log
           (at, actor_id, actor_label, action, target, detail, ip, prev_hash, hash)
         values (@at, @actor::uuid, @label, @action, @target, @detail, @ip, @prev, @hash)''',
      <String, Object?>{
        'at': at,
        'actor': actor.id,
        'label': actor.label,
        'action': action,
        'target': target,
        'detail': detailJson,
        'ip': actor.ip,
        'prev': Uint8List.fromList(prev),
        'hash': hash,
      },
    );
  }

  /// Walks the whole chain. With [anchorId]/[anchorHash] (a tip recorded
  /// outside the database, see BackupService.latestAnchor) it also proves
  /// nothing was cut off the end since that tip was recorded.
  Future<AuditVerification> verify(
    Db db, {
    int? anchorId,
    String? anchorHash,
  }) async {
    // Checked first: a cut-off tail is invisible to the walk below.
    if (anchorId != null && anchorHash != null) {
      final Row? a = await db.one(
        'select hash from audit_log where id = @id',
        <String, Object?>{'id': anchorId},
      );
      if (a == null ||
          _hex(a['hash'] as List<int>) != anchorHash.toLowerCase()) {
        return AuditVerification(
          ok: false,
          checked: 0,
          brokenAtId: anchorId,
          reason:
              'Entry $anchorId, recorded with the last backup, is missing or '
              'different: entries were removed from the end of the log',
        );
      }
    }
    List<int> expectedPrev = genesis;
    int checked = 0;
    int afterId = 0;
    while (true) {
      final List<Row> rows = await db.query(
        '''select id, at, actor_id, actor_label, action, target, detail, ip,
                  prev_hash, hash
             from audit_log where id > @after order by id limit 1000''',
        <String, Object?>{'after': afterId},
      );
      if (rows.isEmpty) break;
      for (final Row r in rows) {
        final int id = r['id'] as int;
        final List<int> prev = r['prev_hash'] as List<int>;
        if (!_eq(prev, expectedPrev)) {
          return AuditVerification(
            ok: false,
            checked: checked,
            brokenAtId: id,
            reason:
                'Row $id does not follow the row before it '
                '(a row was removed or inserted)',
          );
        }
        final Uint8List recomputed = _hash(
          prev,
          (r['at'] as DateTime).toUtc(),
          r['actor_id'] as String?,
          r['actor_label'] as String,
          r['action'] as String,
          r['target'] as String?,
          r['detail'] as String,
          r['ip'] as String?,
        );
        final List<int> stored = r['hash'] as List<int>;
        if (!_eq(recomputed, stored)) {
          return AuditVerification(
            ok: false,
            checked: checked,
            brokenAtId: id,
            reason: 'Row $id was altered after it was written',
          );
        }
        expectedPrev = stored;
        afterId = id;
        checked++;
      }
    }
    return AuditVerification(ok: true, checked: checked);
  }

  Uint8List _hash(
    List<int> prev,
    DateTime at,
    String? actorId,
    String actorLabel,
    String action,
    String? target,
    String detailJson,
    String? ip,
  ) {
    final String body = jsonEncode(<Object?>[
      _hex(prev),
      at.toIso8601String(),
      actorId,
      actorLabel,
      action,
      target,
      detailJson,
      ip,
    ]);
    return Uint8List.fromList(_mac.convert(utf8.encode(body)).bytes);
  }

  /// Millisecond precision survives every round trip through Postgres.
  static DateTime _truncate(DateTime t) => DateTime.fromMillisecondsSinceEpoch(
    t.millisecondsSinceEpoch,
    isUtc: true,
  );

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hex(List<int> b) =>
      b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// JSON with recursively sorted keys, so equal maps hash equally.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? v) {
  if (v is Map) {
    final List<String> keys = v.keys.map((Object? k) => '$k').toList()..sort();
    return <String, Object?>{for (final String k in keys) k: _sorted(v[k])};
  }
  if (v is List) return v.map(_sorted).toList();
  return v;
}
