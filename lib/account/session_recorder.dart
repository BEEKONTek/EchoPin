import 'dart:async';
import 'dart:convert';

import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/outbox.dart';
import 'package:echo_pin/app_info.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/services/key_value_store.dart';
import 'package:echo_pin/session/session_engine.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:echopin_protocol/echopin_protocol.dart';

/// Keeps a sealed record of each live session for emergencies.
///
/// It watches [SessionProvider] and writes down what this device saw:
/// who joined and left, pings and SOS with every answer, boundary
/// crossings, security alarms, and each member's last known distance.
/// The record is sealed to the server's escrow key and goes through the
/// [Outbox], so nobody can read it (this device included) unless a
/// responder opens it on the server, which is audited.
///
/// Checkpoints are uploaded during the session as well as at the end,
/// right away after an SOS or a "Need help". If someone goes missing, the
/// people looking for them should not have to wait for the session to end.
///
/// Demo sessions and signed-out use are never recorded.
class SessionRecorder {
  SessionRecorder({
    required SessionProvider sessions,
    required AccountProvider account,
    required Outbox outbox,
    required KeyValueStore kv,
    String platform = 'unknown',
    DateTime Function()? clock,
    this.checkpointEvery = const Duration(minutes: 10),
    this.urgentDelay = const Duration(seconds: 3),
  }) : _sessions = sessions,
       _account = account,
       _outbox = outbox,
       _kv = kv,
       _platform = platform,
       _clock = clock ?? DateTime.now;

  final SessionProvider _sessions;
  final AccountProvider _account;
  final Outbox _outbox;
  final KeyValueStore _kv;
  final String _platform;
  final DateTime Function() _clock;
  final Duration checkpointEvery;
  final Duration urgentDelay;

  static const String _kDraft = 'echo_pin.session_draft_v1';

  _Log? _log;
  String? _ignoredSessionId;
  Timer? _periodic;
  Timer? _urgent;
  Timer? _draftTimer;
  bool _started = false;

  /// For tests and diagnostics.
  bool get recording => _log != null;
  int get eventCount => _log?.events.length ?? 0;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _recoverDraft();
    _sessions.addListener(_onChange);
    _onChange();
  }

  void dispose() {
    _sessions.removeListener(_onChange);
    _periodic?.cancel();
    _urgent?.cancel();
    _draftTimer?.cancel();
  }

  // ── Observation ────────────────────────────────────────────────────────

  void _onChange() {
    final Session? s = _sessions.session;
    final _Log? log = _log;
    if (s == null) {
      // Let the provider finish its own bookkeeping (e.g. set the
      // "ended after 8 hours" reason) before writing the last entry.
      if (log != null) Timer(Duration.zero, () => unawaited(_finish(log)));
      _log = null;
      _ignoredSessionId = null;
      return;
    }
    if (log != null && log.sessionId != s.id) {
      unawaited(_finish(log, reason: 'Switched to another session'));
      _log = null;
    }
    if (_log == null) {
      if (_ignoredSessionId == s.id) return;
      final String? accountId = _account.account?.id;
      if (s.demo || accountId == null) {
        // Not recorded; also not later, if they sign in mid-session, to
        // avoid a log that silently misses its beginning.
        _ignoredSessionId = s.id;
        return;
      }
      _log = _Log(
        accountId: accountId,
        sessionId: s.id,
        sessionName: s.name,
        startedAt: _clock().toUtc(),
        boundaryMeters: s.boundaryRadiusMeters,
        selfPeerId: _sessions.selfPeerId ?? '?',
        selfName: _sessions.selfName ?? '?',
        sessionTag: _sessions.engine?.credentials.serverTag,
      );
      _event(SessionLogEvent.started, <String, Object?>{
        'boundaryMeters': s.boundaryRadiusMeters.round(),
        'self': _sessions.selfName,
      });
      _periodic?.cancel();
      _periodic = Timer.periodic(
        checkpointEvery,
        (_) => unawaited(_checkpoint()),
      );
    }
    _diff(s);
  }

  void _diff(Session s) {
    final _Log log = _log!;
    final DateTime now = _clock().toUtc();
    final SessionEngine? engine = _sessions.engine;
    bool urgent = false;
    log.boundaryMeters = s.boundaryRadiusMeters;

    // Members.
    final Map<String, SessionMember> members =
        engine?.members ?? const <String, SessionMember>{};
    for (final SessionMember m in members.values) {
      final _Member? known = log.members[m.peerId];
      if (known == null) {
        log.members[m.peerId] = _Member(m.name, m.safetyCode, now)
          ..lastHeard = m.lastHeard;
        _event(SessionLogEvent.memberJoined, <String, Object?>{
          'peerId': m.peerId,
          'name': m.name,
        });
      } else {
        known.name = m.name;
        known.lastHeard = m.lastHeard;
        known.present = true;
      }
    }
    for (final MapEntry<String, _Member> e in log.members.entries) {
      if (e.value.present && !members.containsKey(e.key) && engine != null) {
        e.value.present = false;
        _event(SessionLogEvent.memberLeft, <String, Object?>{
          'peerId': e.key,
          'name': e.value.name,
        });
      }
    }

    // Distances and boundary crossings (privacy-noised values, as shown).
    for (final PeerPresence p in s.peers) {
      if (!p.authenticated || !p.hasDistance) continue;
      final _Member? m = log.members[p.id];
      if (m == null) continue;
      m.lastDistance = p.distanceMeters;
      m.lastDistanceAt = now;
      m.verified = p.verified;
      final bool outside = p.distanceMeters > s.boundaryRadiusMeters;
      if (outside && !log.outside.contains(p.id)) {
        log.outside.add(p.id);
        log.crossings++;
        _event(SessionLogEvent.leftBoundary, <String, Object?>{
          'peerId': p.id,
          'name': p.label,
          'distanceMeters': p.distanceMeters.round(),
          'boundaryMeters': s.boundaryRadiusMeters.round(),
        });
      } else if (!outside && log.outside.remove(p.id)) {
        _event(SessionLogEvent.returnedToBoundary, <String, Object?>{
          'peerId': p.id,
          'name': p.label,
          'distanceMeters': p.distanceMeters.round(),
        });
      }
    }

    // Pings this device sent.
    for (final OutgoingPing ping in _sessions.outgoingPings) {
      final Map<String, String>? seen = log.outgoing[ping.id];
      if (seen == null) {
        log.outgoing[ping.id] = <String, String>{};
        if (ping.kind == PingKind.sos) {
          log.sos++;
          urgent = true;
          _event(SessionLogEvent.sosRaised, <String, Object?>{
            'pingId': ping.id,
            'by': log.selfName,
            'self': true,
            'note': ping.note,
          });
        } else {
          log.checkIns++;
          _event(SessionLogEvent.pingSent, <String, Object?>{
            'pingId': ping.id,
            'kind': ping.kind.wire,
            'recipients': ping.recipients.length,
            'everyone': ping.broadcast,
            'note': ping.note,
          });
        }
      }
      final Map<String, String> states = log.outgoing[ping.id]!;
      for (final RecipientStatus r in ping.recipients.values) {
        final String key = '${r.state.name}/${r.response?.wire ?? ''}';
        if (states[r.peerId] == key) continue;
        states[r.peerId] = key;
        if (r.state == DeliveryState.sending) continue;
        if (r.response == PingResponse.help) {
          log.help++;
          urgent = true;
        }
        _event(SessionLogEvent.pingStatus, <String, Object?>{
          'pingId': ping.id,
          'peerId': r.peerId,
          'name': r.name,
          'state': r.state.name,
          'response': r.response?.label,
        });
      }
      if (ping.cancelled && !log.cancelled.contains(ping.id)) {
        log.cancelled.add(ping.id);
        if (ping.kind == PingKind.sos) {
          _event(SessionLogEvent.sosResolved, <String, Object?>{
            'pingId': ping.id,
            'by': log.selfName,
            'self': true,
          });
        }
      }
    }

    // Pings this device received.
    for (final IncomingPing ping in _sessions.incomingPings) {
      final String key = '${ping.response?.wire ?? ''}/${ping.resolved}';
      final String? seen = log.incoming[ping.id];
      if (seen == null) {
        if (ping.kind == PingKind.sos) {
          log.sos++;
          urgent = true;
          _event(SessionLogEvent.sosRaised, <String, Object?>{
            'pingId': ping.id,
            'by': ping.fromName,
            'peerId': ping.fromId,
            'note': ping.note,
          });
        } else {
          _event(SessionLogEvent.pingReceived, <String, Object?>{
            'pingId': ping.id,
            'from': ping.fromName,
            'peerId': ping.fromId,
            'note': ping.note,
          });
        }
      }
      if (seen != key) {
        final String? before = seen?.split('/').first;
        if (ping.response != null && before != ping.response!.wire) {
          if (ping.response == PingResponse.help) {
            log.help++;
            urgent = true;
          }
          _event(SessionLogEvent.pingAnswered, <String, Object?>{
            'pingId': ping.id,
            'to': ping.fromName,
            'response': ping.response!.label,
          });
        }
        if (ping.resolved && !(seen?.endsWith('/true') ?? false)) {
          _event(SessionLogEvent.sosResolved, <String, Object?>{
            'pingId': ping.id,
            'by': ping.fromName,
          });
        }
        log.incoming[ping.id] = key;
      }
    }

    // Security alarms (the provider keeps the newest 100).
    final List<SecurityError> security = _sessions.securityLog;
    if (security.length < log.securitySeen) log.securitySeen = 0;
    for (final SecurityError e in security.skip(log.securitySeen)) {
      if (e.alarming) {
        _event(SessionLogEvent.security, <String, Object?>{
          'problem': e.problem.name,
          'peerId': e.peerId,
          'message': e.message,
        });
      }
    }
    log.securitySeen = security.length;

    if (engine != null) log.diagnostics = _diagnostics(engine);
    if (urgent) {
      _urgent?.cancel();
      _urgent = Timer(urgentDelay, () => unawaited(_checkpoint()));
    }
    _scheduleDraft();
  }

  void _event(String type, Map<String, Object?> fields, [_Log? target]) {
    final _Log log = target ?? _log!;
    if (log.events.length >= ProtocolLimits.maxLogEvents) {
      log.truncated = true;
      return;
    }
    log.events.add(<String, Object?>{
      'at': _clock().toUtc().toIso8601String(),
      'type': type,
      for (final MapEntry<String, Object?> f in fields.entries)
        if (f.value != null) f.key: f.value,
    });
  }

  // ── Uploads ────────────────────────────────────────────────────────────

  Future<void> _checkpoint() async {
    final _Log? log = _log;
    if (log == null || log.events.length == log.eventsAtCheckpoint) return;
    log.eventsAtCheckpoint = log.events.length;
    await _enqueue(log, finalLog: false, reason: null);
  }

  Future<void> _finish(_Log log, {String? reason}) async {
    _periodic?.cancel();
    _urgent?.cancel();
    _draftTimer?.cancel();
    final String why = reason ?? _sessions.endedReason ?? 'Left the session';
    _event(SessionLogEvent.ended, <String, Object?>{'reason': why}, log);
    await _enqueue(log, finalLog: true, reason: why);
    await _kv.delete(_kDraft);
    if (log.diagnostics.isNotEmpty) await _enqueueDiagnostics(log);
  }

  Future<void> _enqueue(
    _Log log, {
    required bool finalLog,
    required String? reason,
  }) async {
    if (_account.account?.id != log.accountId) return;
    log.sequence++;
    try {
      await _outbox.enqueue(
        OutboxKind.sessionLog,
        log.body(
          endedAt: finalLog ? _clock().toUtc() : null,
          reason: reason,
          finalLog: finalLog,
        ),
      );
      unawaited(_outbox.flush());
    } on EchoError {
      // Signed out between the check and the enqueue; nothing to do.
    }
  }

  Future<void> _enqueueDiagnostics(_Log log) async {
    final Map<String, Object?> d = log.diagnostics;
    final bool radioDown = (d['radios'] as String? ?? '').contains('down');
    final int rejected = d['rejected'] as int? ?? 0;
    final bool alarms = log.events.any(
      (Map<String, Object?> e) => e['type'] == SessionLogEvent.security,
    );
    final DiagnosticLevel level = alarms
        ? DiagnosticLevel.error
        : (radioDown || rejected > 20)
        ? DiagnosticLevel.warning
        : DiagnosticLevel.info;
    try {
      await _outbox.enqueue(OutboxKind.diagnostics, <String, dynamic>{
        'level': level.wire,
        'appVersion': kAppVersion,
        'platform': _platform,
        'summary': alarms
            ? 'Security alarms during a session'
            : radioDown
            ? 'A radio was down during a session'
            : 'Session ended normally',
        'payload': <String, Object?>{
          ...d,
          'sessionId': log.sessionId,
          'durationMinutes': _clock()
              .toUtc()
              .difference(log.startedAt)
              .inMinutes,
          'members': log.members.length,
          'outboxRejected': _outbox.rejectedCount,
        },
      });
      unawaited(_outbox.flush());
    } on EchoError {
      // Signed out.
    }
  }

  Map<String, Object?> _diagnostics(SessionEngine engine) {
    final int rejected = engine.messenger.rejections.values.fold(
      0,
      (int a, int b) => a + b,
    );
    return <String, Object?>{
      'radios': engine.transports
          .map((MessageTransport t) => '${t.label}: ${t.status.health.name}')
          .join(', '),
      'sent': engine.messenger.sentCount,
      'accepted': engine.messenger.acceptedCount,
      'rejected': rejected,
      'rejections': <String, int>{
        for (final MapEntry<SecurityProblem, int> e
            in engine.messenger.rejections.entries)
          e.key.name: e.value,
      },
    };
  }

  // ── Crash safety ───────────────────────────────────────────────────────

  /// Writes the would-be final log a few seconds after changes, so a log
  /// survives the app being killed. The next start uploads it.
  void _scheduleDraft() {
    if (_draftTimer?.isActive ?? false) return;
    _draftTimer = Timer(const Duration(seconds: 5), () {
      final _Log? log = _log;
      if (log == null) return;
      unawaited(
        _kv.write(
          _kDraft,
          jsonEncode(<String, Object?>{
            'accountId': log.accountId,
            'body': log.body(
              endedAt: _clock().toUtc(),
              reason: 'The app closed before the session ended',
              finalLog: true,
              sequenceOverride: log.sequence + 1,
            ),
          }),
        ),
      );
    });
  }

  Future<void> _recoverDraft() async {
    final String? raw = await _kv.read(_kDraft);
    if (raw == null) return;
    await _kv.delete(_kDraft);
    try {
      final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['accountId'] != _account.account?.id) return;
      await _outbox.enqueue(
        OutboxKind.sessionLog,
        j['body'] as Map<String, dynamic>,
      );
    } catch (_) {
      // A damaged draft is dropped rather than blocking startup.
    }
  }
}

class _Member {
  _Member(this.name, this.safetyCode, this.firstSeen);
  String name;
  final String safetyCode;
  final DateTime firstSeen;
  DateTime? lastHeard;
  double? lastDistance;
  DateTime? lastDistanceAt;
  bool verified = false;
  bool present = true;

  Map<String, Object?> toJson(String peerId) => <String, Object?>{
    'peerId': peerId,
    'name': name,
    'safetyCode': safetyCode,
    'firstSeen': firstSeen.toIso8601String(),
    'lastHeard': lastHeard?.toUtc().toIso8601String(),
    'lastDistanceMeters': lastDistance?.round(),
    'lastDistanceAt': lastDistanceAt?.toIso8601String(),
    'verifiedInPerson': verified,
    'presentAtEnd': present,
  };
}

class _Log {
  _Log({
    required this.accountId,
    required this.sessionId,
    required this.sessionName,
    required this.startedAt,
    required this.boundaryMeters,
    required this.selfPeerId,
    required this.selfName,
    this.sessionTag,
  });

  final String accountId;

  /// Proves to the server that this phone held the invite code.
  final List<int>? sessionTag;
  final String sessionId;
  final String sessionName;
  final DateTime startedAt;
  double boundaryMeters;
  final String selfPeerId;
  final String selfName;
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];
  final Map<String, _Member> members = <String, _Member>{};
  final Map<String, Map<String, String>> outgoing =
      <String, Map<String, String>>{};
  final Map<String, String> incoming = <String, String>{};
  final Set<String> cancelled = <String>{};
  final Set<String> outside = <String>{};
  int securitySeen = 0;
  int sos = 0;
  int checkIns = 0;
  int help = 0;
  int crossings = 0;
  int sequence = 0;
  int eventsAtCheckpoint = 0;
  bool truncated = false;
  Map<String, Object?> diagnostics = <String, Object?>{};

  Map<String, dynamic> body({
    required DateTime? endedAt,
    required String? reason,
    required bool finalLog,
    int? sequenceOverride,
  }) => <String, dynamic>{
    'sessionId': sessionId,
    'sessionName': sessionName,
    'startedAt': startedAt.toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt.toIso8601String(),
    'memberCount': members.length + 1,
    'sosCount': sos,
    'checkInCount': checkIns,
    'helpCount': help,
    'crossingCount': crossings,
    if (reason != null) 'endReason': reason,
    'sequence': sequenceOverride ?? sequence,
    'final': finalLog,
    if (sessionTag != null) 'sessionTag': base64.encode(sessionTag!),
    // Sealed by the outbox before it is stored for long or sent.
    'plain': <String, Object?>{
      'format': 1,
      'sessionId': sessionId,
      'sessionName': sessionName,
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt?.toIso8601String(),
      'endReason': reason,
      'final': finalLog,
      'boundaryMeters': boundaryMeters.round(),
      'recordedBy': <String, Object?>{'peerId': selfPeerId, 'name': selfName},
      'members': <Object?>[
        for (final MapEntry<String, _Member> m in members.entries)
          m.value.toJson(m.key),
      ],
      'events': events,
      'truncated': truncated,
    },
  };
}
