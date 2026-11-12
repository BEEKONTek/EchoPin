import 'dart:convert';
import 'dart:typed_data';

import 'package:echopin_protocol/echopin_protocol.dart';

import 'api/http.dart';
import 'auth/auth_service.dart';
import 'db/database.dart';
import 'security/custodian.dart';
import 'security/keys.dart';

/// What devices send up: diagnostics, sealed session logs and reports.
///
/// Nothing here can read a sealed log. Ingest only checks the blob's shape
/// and that it names an escrow key this server holds.
class TelemetryService {
  TelemetryService({
    required Db db,
    required ServerKeys keys,
    CustodianKeys? custodian,
    this.custodianRequired = false,
    DateTime Function()? clock,
  }) : _db = db,
       _keys = keys,
       _custodian = custodian ?? CustodianKeys(const <String>[]),
       _clock = clock ?? DateTime.now;

  final Db _db;
  final ServerKeys _keys;
  final CustodianKeys _custodian;

  /// Refuse logs that are sealed only once (to the server's key).
  final bool custodianRequired;
  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  Future<void> addDiagnostics(
    AuthContext ctx,
    Map<String, dynamic> body,
  ) async {
    final DiagnosticLevel level =
        DiagnosticLevel.fromWire(body['level']) ??
        (throw ApiException.badRequest('level must be info, warning or error'));
    final Object? payload = body['payload'];
    if (payload is! Map) {
      throw ApiException.badRequest('payload must be an object');
    }
    final String encoded = jsonEncode(payload);
    if (encoded.length > ProtocolLimits.maxDiagnosticsBytes) {
      throw const ApiException(413, 'too_large', 'Diagnostics are too large');
    }
    await _db.execute(
      '''insert into diagnostics
           (account_id, device_id, level, app_version, platform, summary, payload, received_at)
         values (@a::uuid, @d::uuid, @l, @v, @p, @s, @j::jsonb, @now)''',
      <String, Object?>{
        'a': ctx.accountId,
        'd': ctx.deviceId,
        'l': level.wire,
        'v': body.str('appVersion', max: 40),
        'p': body.str('platform', max: 40),
        's': body.str('summary', max: 200),
        'j': encoded,
        'now': _now,
      },
    );
  }

  /// Idempotent on the client-chosen `id`, so the outbox can retry safely.
  Future<bool> addSessionLog(AuthContext ctx, Map<String, dynamic> body) async {
    final String id = body.str('id', max: 36);
    if (!_uuid.hasMatch(id)) throw ApiException.badRequest('id must be a UUID');
    final String keyId = body.str('keyId', max: 32);
    if (!_keys.escrowKeys.containsKey(keyId)) {
      throw const ApiException(
        409,
        'unknown_escrow_key',
        'This log was sealed to a key the server does not have. Update the app',
      );
    }
    final List<int> sealed = body.b64(
      'sealed',
      maxLength: ProtocolLimits.maxSealedLogBytes,
    );
    try {
      SealedBox.checkStructure(sealed);
    } on SealedBoxException catch (e) {
      throw ApiException.badRequest(e.message);
    }
    // Second seal: which custodian key the inside layer is sealed to.
    final String? custodianKeyId = body.optStr('custodianKeyId', max: 32);
    if (custodianKeyId != null &&
        !_custodian.publicKeys.containsKey(custodianKeyId)) {
      throw const ApiException(
        409,
        'unknown_custodian_key',
        'This log was sealed to a custodian key the server does not accept. Update the app',
      );
    }
    if (custodianKeyId == null && custodianRequired) {
      throw const ApiException(
        409,
        'custodian_required',
        'This server only accepts double-sealed logs. Update the app',
      );
    }
    // Session tag: proves the uploader knew the session key (see
    // AdminService.session). 16 bytes; optional for older apps.
    final List<int>? tag = body['sessionTag'] == null
        ? null
        : body.b64('sessionTag', length: 16);
    int count(String k) =>
        (body[k] is int) ? (body[k] as int).clamp(0, 100000) : 0;
    final int inserted = await _db.execute(
      '''insert into session_logs
           (id, session_id, session_name, account_id, device_id, started_at, ended_at,
            member_count, sos_count, checkin_count, help_count, crossing_count,
            end_reason, key_id, sealed, received_at, sequence, is_final,
            custodian_key_id, session_tag)
         values (@id::uuid, @sid, @name, @a::uuid, @d::uuid, @start, @end,
                 @members, @sos, @checkins, @help, @crossings,
                 @reason, @key, @sealed, @now, @seq, @final,
                 @custodian, @tag)
         on conflict (id) do nothing''',
      <String, Object?>{
        'id': id,
        'sid': body.str('sessionId', max: 64),
        'name': body.str('sessionName', max: 80),
        'a': ctx.accountId,
        'd': ctx.deviceId,
        'start': body.time('startedAt'),
        'end': body.optTime('endedAt'),
        'members': count('memberCount'),
        'sos': count('sosCount'),
        'checkins': count('checkInCount'),
        'help': count('helpCount'),
        'crossings': count('crossingCount'),
        'reason': body.optStr('endReason', max: 200),
        'key': keyId,
        'sealed': Uint8List.fromList(sealed),
        'now': _now,
        'seq': count('sequence'),
        'final': body['final'] != false,
        'custodian': custodianKeyId,
        'tag': tag == null ? null : Uint8List.fromList(tag),
      },
    );
    return inserted > 0;
  }

  Future<Map<String, Object?>> addReport(
    AuthContext ctx,
    Map<String, dynamic> body,
  ) async {
    final ReportCategory category =
        ReportCategory.fromWire(body['category']) ??
        (throw ApiException.badRequest('Pick what the report is about'));
    // Safety reports default to high; a person can raise but the server
    // never lowers a safety report below high.
    ReportSeverity severity =
        ReportSeverity.fromWire(body['severity']) ??
        (category == ReportCategory.safety
            ? ReportSeverity.high
            : ReportSeverity.normal);
    if (category == ReportCategory.safety &&
        severity.index < ReportSeverity.high.index) {
      severity = ReportSeverity.high;
    }
    final Object? diagnostics = body['diagnostics'];
    if (diagnostics != null && diagnostics is! Map) {
      throw ApiException.badRequest('diagnostics must be an object');
    }
    final String? diagJson = diagnostics == null
        ? null
        : jsonEncode(diagnostics);
    if (diagJson != null &&
        diagJson.length > ProtocolLimits.maxDiagnosticsBytes) {
      throw const ApiException(
        413,
        'too_large',
        'Attached diagnostics are too large',
      );
    }
    final DateTime now = _now;
    final Row row = (await _db.one(
      '''insert into reports
           (account_id, device_id, category, severity, subject, body, session_id,
            diagnostics, created_at, updated_at)
         values (@a::uuid, @d::uuid, @c, @s, @subj, @body, @sid, @diag::jsonb, @now, @now)
         returning id, status, created_at''',
      <String, Object?>{
        'a': ctx.accountId,
        'd': ctx.deviceId,
        'c': category.wire,
        's': severity.wire,
        'subj': body.str('subject', max: ProtocolLimits.maxReportSubject),
        'body': body
            .str('body', max: ProtocolLimits.maxReportBody, trim: false)
            .trim(),
        'sid': body.optStr('sessionId', max: 64),
        'diag': diagJson,
        'now': now,
      },
    ))!;
    return <String, Object?>{
      'id': row['id'],
      'status': row['status'],
      'severity': severity.wire,
      'createdAt': row['created_at'],
    };
  }

  /// A person's own reports and where each stands. No admin notes.
  Future<List<Map<String, Object?>>> myReports(AuthContext ctx) async {
    final List<Row> rows = await _db.query(
      '''select id, category, severity, status, subject, resolution, created_at, updated_at
           from reports where account_id = @a::uuid order by created_at desc limit 100''',
      <String, Object?>{'a': ctx.accountId},
    );
    return rows
        .map(
          (Row r) => <String, Object?>{
            'id': r['id'],
            'category': r['category'],
            'severity': r['severity'],
            'status': r['status'],
            'subject': r['subject'],
            'resolution': r['resolution'],
            'createdAt': r['created_at'],
            'updatedAt': r['updated_at'],
          },
        )
        .toList();
  }

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}
