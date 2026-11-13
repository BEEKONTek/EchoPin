import 'dart:async';
import 'dart:math' as math;

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/security/secure_messenger.dart';
import 'package:echo_pin/security/session_credentials.dart';
import 'package:echo_pin/security/session_identity.dart';
import 'package:echo_pin/security/wire.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:flutter/foundation.dart';

/// Someone whose messages have been authenticated in this session.
@immutable
class SessionMember {
  const SessionMember({
    required this.peerId,
    required this.name,
    required this.publicKey,
    required this.safetyCode,
    required this.links,
    required this.firstSeen,
    required this.lastHeard,
    this.named = false,
  });

  final String peerId;
  final String name;
  final List<int> publicKey;

  /// 12-digit code to compare in person.
  final String safetyCode;
  final Set<PeerLink> links;
  final DateTime firstSeen;
  final DateTime lastHeard;

  /// False until their hello (with display name) arrives.
  final bool named;

  SessionMember copyWith({
    String? name,
    Set<PeerLink>? links,
    DateTime? lastHeard,
    bool? named,
  }) {
    return SessionMember(
      peerId: peerId,
      name: name ?? this.name,
      publicKey: publicKey,
      safetyCode: safetyCode,
      links: links ?? this.links,
      firstSeen: firstSeen,
      lastHeard: lastHeard ?? this.lastHeard,
      named: named ?? this.named,
    );
  }
}

/// Validates and normalises a display name typed on this device.
String validateDisplayName(String raw) {
  final String cleaned = sanitizeName(raw);
  if (cleaned.isEmpty) {
    throw const InvalidInputError('Your name', 'cannot be empty');
  }
  if (cleaned.length > maxNameLength) {
    throw const InvalidInputError(
      'Your name',
      'must be at most $maxNameLength characters',
    );
  }
  return cleaned;
}

const int maxNameLength = 24;
const int maxNoteLength = 80;

/// Strips control / bidi-override characters and collapses whitespace.
/// Applied to every name that arrives from the network, which is untrusted.
String sanitizeName(String raw) {
  return raw
      .replaceAll(
        RegExp(r'[\u0000-\u001F\u007F\u202A-\u202E\u2066-\u2069\u200E\u200F]'),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// The protocol engine for one session on this device.
///
/// Owns the session identity, the [SecureMessenger] and the transports, and
/// implements membership (hello / bye) and pings (check-in, SOS) with
/// receipts, replies and retries. Contains no UI and no Flutter widgets, so
/// tests run complete multi-person sessions in memory.
class SessionEngine {
  SessionEngine._({
    required this.credentials,
    required this.identity,
    required this.displayName,
    required List<MessageTransport> transports,
    required this.helloInterval,
    required this.retryInterval,
    required this.checkInAttempts,
    required this.sosAttempts,
    required this.replyAttempts,
    required this.checkInCooldown,
    required int maxMembers,
    required DateTime Function() clock,
  }) : _transports = List<MessageTransport>.unmodifiable(transports),
       _clock = clock,
       _messenger = SecureMessenger(
         credentials: credentials,
         identity: identity,
         maxMembers: maxMembers,
         clock: clock,
       );

  static Future<SessionEngine> start({
    required SessionCredentials credentials,
    required String displayName,
    required List<MessageTransport> transports,
    SessionIdentity? identity,
    Duration helloInterval = const Duration(seconds: 20),
    Duration retryInterval = const Duration(seconds: 4),
    int checkInAttempts = 8,
    int sosAttempts = 30,
    int replyAttempts = 8,
    Duration checkInCooldown = const Duration(seconds: 10),
    int maxMembers = 20,
    DateTime Function()? clock,
  }) async {
    final SessionEngine engine = SessionEngine._(
      credentials: credentials,
      identity: identity ?? await SessionIdentity.generate(),
      displayName: validateDisplayName(displayName),
      transports: transports,
      helloInterval: helloInterval,
      retryInterval: retryInterval,
      checkInAttempts: checkInAttempts,
      sosAttempts: sosAttempts,
      replyAttempts: replyAttempts,
      checkInCooldown: checkInCooldown,
      maxMembers: maxMembers,
      clock: clock ?? DateTime.now,
    );
    await engine._start();
    return engine;
  }

  final SessionCredentials credentials;
  final SessionIdentity identity;
  String displayName;
  final Duration helloInterval;
  final Duration retryInterval;
  final int checkInAttempts;
  final int sosAttempts;
  final int replyAttempts;
  final Duration checkInCooldown;

  final List<MessageTransport> _transports;
  final DateTime Function() _clock;
  final SecureMessenger _messenger;
  final math.Random _random = math.Random.secure();

  final Map<String, SessionMember> _members = <String, SessionMember>{};
  final Map<String, OutgoingPing> _outgoing = <String, OutgoingPing>{};
  final Map<String, IncomingPing> _incoming = <String, IncomingPing>{};
  final Map<String, _PendingReply> _pendingReplies = <String, _PendingReply>{};

  /// "I'm safe" notices not yet confirmed, by SOS id.
  final Map<String, _PendingSafe> _pendingSafe = <String, _PendingSafe>{};
  final Map<String, DateTime> _lastHelloTo = <String, DateTime>{};
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<EchoError> _errors =
      StreamController<EchoError>.broadcast();
  final StreamController<IncomingPing> _pingAlerts =
      StreamController<IncomingPing>.broadcast();

  Timer? _helloTimer;
  Timer? _retryTimer;
  bool _anyUp = false;
  DateTime? _lastCheckIn;
  bool _reportedNoTransport = false;
  bool _stopped = false;

  // ── Read side ──────────────────────────────────────────────────────────

  String get peerId => identity.peerId;
  String get sessionId => credentials.sessionId;
  String get safetyCode => identity.safetyCode(sessionId);
  bool get isStopped => _stopped;

  Map<String, SessionMember> get members =>
      Map<String, SessionMember>.unmodifiable(_members);

  /// Newest first.
  List<OutgoingPing> get outgoingPings =>
      _outgoing.values.toList().reversed.toList(growable: false);

  /// Newest first.
  List<IncomingPing> get incomingPings =>
      _incoming.values.toList().reversed.toList(growable: false);

  List<MessageTransport> get transports => _transports;
  SecureMessenger get messenger => _messenger;

  bool get anyTransportUp =>
      _transports.any((MessageTransport t) => t.status.isUp);

  /// Fires whenever members, pings or transport status change.
  Stream<void> get changes => _changes.stream;

  /// Problems worth showing: security rejections, delivery failures.
  Stream<EchoError> get errors => _errors.stream;

  /// A new ping arrived for this device.
  Stream<IncomingPing> get pingAlerts => _pingAlerts.stream;

  // ── Lifecycle ──────────────────────────────────────────────────────────

  Future<void> _start() async {
    _subs.add(_messenger.events.listen(_emitError));
    for (final MessageTransport t in _transports) {
      _subs.add(t.frames.listen(_onFrame));
      try {
        await t.start(sessionId: sessionId, peerId: peerId);
      } catch (e) {
        _emitError(TransportError(t.label, '$e'));
      }
    }
    // Status is watched only from here on, so the start-up transitions
    // above do not each announce us; the single hello below does that.
    _anyUp = anyTransportUp;
    for (final MessageTransport t in _transports) {
      _subs.add(t.statusChanges.listen((_) => _onTransportStatus()));
    }
    _helloTimer = Timer.periodic(helloInterval, (_) => unawaited(_hello()));
    _retryTimer = Timer.periodic(retryInterval, (_) => unawaited(_retry()));
    await _hello();
    _notify();
  }

  /// Sends bye, stops radios and destroys key material.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _helloTimer?.cancel();
    _retryTimer?.cancel();
    try {
      await _broadcast(
        MessageKind.bye,
        const <String, Object?>{},
      ).timeout(const Duration(seconds: 2));
    } catch (_) {} // best effort: leaving; nothing left to report to
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    for (final MessageTransport t in _transports) {
      try {
        await t.stop();
      } catch (_) {} // best effort: leaving; nothing left to report to
    }
    await _messenger.dispose();
    identity.wipe();
    credentials.wipe();
    _members.clear();
    unawaited(_changes.close());
    unawaited(_errors.close());
    unawaited(_pingAlerts.close());
  }

  Future<void> rename(String name) async {
    displayName = validateDisplayName(name);
    _lastHelloTo.clear();
    await _hello();
  }

  // ── Pings ──────────────────────────────────────────────────────────────

  /// Sends a check-in or SOS. [to] = null means everyone.
  ///
  /// Throws [NoRecipientsError], [RateLimitedError] or [InvalidInputError].
  Future<OutgoingPing> ping({
    required PingKind kind,
    Set<String>? to,
    String? note,
  }) async {
    _ensureRunning();
    final String? cleanNote = _validateNote(note);
    final DateTime now = _clock();

    if (kind == PingKind.checkIn) {
      final DateTime? last = _lastCheckIn;
      if (last != null && now.difference(last) < checkInCooldown) {
        throw RateLimitedError(checkInCooldown - now.difference(last));
      }
    }
    if (kind == PingKind.sos) {
      // One live SOS at a time: re-sending restarts its retries.
      for (final OutgoingPing p in _outgoing.values) {
        if (p.kind == PingKind.sos && !p.cancelled) {
          _outgoing[p.id] = p.copyWith(
            recipients: <String, RecipientStatus>{
              for (final MapEntry<String, RecipientStatus> e in _withNewMembers(
                p,
              ).recipients.entries)
                e.key: e.value.state == DeliveryState.unreachable
                    ? e.value.copyWith(
                        state: DeliveryState.sending,
                        attempts: 0,
                      )
                    : e.value,
            },
          );
          await _sendPingFrame(_outgoing[p.id]!);
          _notify();
          return _outgoing[p.id]!;
        }
      }
    }

    final Set<String> targets = (to ?? _members.keys.toSet())
        .where(_members.containsKey)
        .toSet();
    // An SOS to everyone goes out even when nobody is in range yet: it is
    // delivered to whoever joins while it is live. Check-ins need someone.
    final bool openSos = kind == PingKind.sos && to == null;
    if (targets.isEmpty && !openSos) throw const NoRecipientsError();
    if (targets.length > Wire.maxRecipients) {
      throw const InvalidInputError('Ping', 'can reach at most 32 people');
    }

    final OutgoingPing ping = OutgoingPing(
      id: _newId(),
      kind: kind,
      createdAt: now,
      note: cleanNote,
      broadcast: to == null,
      recipients: <String, RecipientStatus>{
        for (final String id in targets)
          id: RecipientStatus(peerId: id, name: _members[id]!.name),
      },
    );
    _outgoing[ping.id] = ping;
    if (kind == PingKind.checkIn) _lastCheckIn = now;
    await _sendPingFrame(ping);
    _notify();
    return ping;
  }

  /// Stops retrying [pingId]. Ending an SOS also tells everyone the sender
  /// is safe, so their alerts resolve by themselves; that notice is retried
  /// like a ping until each recipient confirms it.
  Future<void> cancelPing(String pingId) async {
    final OutgoingPing? p = _outgoing[pingId];
    if (p == null || p.cancelled) return;
    _outgoing[pingId] = p.copyWith(cancelled: true);
    _notify();
    if (p.kind == PingKind.sos && !_stopped && p.recipients.isNotEmpty) {
      final _PendingSafe safe = _PendingSafe(p.id, p.recipients.keys.toSet());
      _pendingSafe[p.id] = safe;
      await _sendSafe(safe);
    }
  }

  /// Answers a ping this device received. Retried until acknowledged.
  Future<void> respond(
    String fromId,
    String pingId,
    PingResponse response,
  ) async {
    _ensureRunning();
    final String key = _incomingKey(fromId, pingId);
    final IncomingPing? p = _incoming[key];
    if (p == null) throw StateError('Unknown ping');
    _incoming[key] = p.copyWith(response: response);
    _pendingReplies[key] = _PendingReply(fromId, pingId, response);
    await _sendReply(_pendingReplies[key]!);
    _notify();
  }

  void dismiss(String fromId, String pingId) {
    final String key = _incomingKey(fromId, pingId);
    final IncomingPing? p = _incoming[key];
    if (p == null) return;
    _incoming[key] = p.copyWith(dismissed: true);
    _notify();
  }

  // ── Incoming ───────────────────────────────────────────────────────────

  Future<void> _onFrame(TransportFrame frame) async {
    if (_stopped) return;
    final SecureMessage? m;
    try {
      m = await _messenger.open(frame.bytes);
    } catch (e) {
      return; // Never let one bad frame break the stream.
    }
    if (m == null || _stopped) return;
    if (!m.isFor(peerId)) return;

    final bool isNew = !_members.containsKey(m.senderId);
    _touchMember(m, frame.link);

    switch (m.kind) {
      case MessageKind.hello:
        final String name = sanitizeName('${m.body['n'] ?? ''}');
        if (name.isNotEmpty) {
          final String clipped = name.length > maxNameLength
              ? name.substring(0, maxNameLength)
              : name;
          _members[m.senderId] = _members[m.senderId]!.copyWith(
            name: clipped,
            named: true,
          );
          _renameInPings(m.senderId, clipped);
        }
      case MessageKind.ping:
        await _onPing(m);
      case MessageKind.receipt:
        _onReceipt(m);
      case MessageKind.reply:
        await _onReply(m);
      case MessageKind.bye:
        _members.remove(m.senderId);
        _lastHelloTo.remove(m.senderId);
    }

    if (isNew && m.kind != MessageKind.bye) {
      // Introduce ourselves so the newcomer learns our name right away, and
      // include them in any live SOS.
      unawaited(_hello(to: m.senderId));
      for (final OutgoingPing p in _outgoing.values.toList()) {
        if (p.kind == PingKind.sos && !p.cancelled) {
          _outgoing[p.id] = _withNewMembers(p);
          unawaited(_sendPingFrame(_outgoing[p.id]!));
        }
      }
    }
    _notify();
  }

  void _touchMember(SecureMessage m, PeerLink link) {
    final DateTime now = _clock();
    final SessionMember? existing = _members[m.senderId];
    if (existing == null) {
      _members[m.senderId] = SessionMember(
        peerId: m.senderId,
        name: 'Peer ${m.senderId.substring(0, 4)}',
        publicKey: m.senderKey,
        safetyCode: safetyCodeFor(sessionId, m.senderKey),
        links: <PeerLink>{link},
        firstSeen: now,
        lastHeard: now,
      );
    } else {
      _members[m.senderId] = existing.copyWith(
        lastHeard: now,
        links: <PeerLink>{...existing.links, link},
      );
    }
  }

  Future<void> _onPing(SecureMessage m) async {
    final String? id = _idFrom(m.body['id']);
    final PingKind? kind = PingKind.fromWire(m.body['k']);
    if (id == null || kind == null) return;
    final String key = _incomingKey(m.senderId, id);
    if (m.body['x'] == true) {
      final IncomingPing? existing = _incoming[key];
      if (existing != null && !existing.resolved) {
        _incoming[key] = existing.copyWith(resolved: true);
      }
      // Confirm even if the SOS itself never arrived, so the sender stops.
      await _send(
        MessageKind.receipt,
        <String, Object?>{'id': id, 'for': 'safe'},
        to: <String>{m.senderId},
        urgency: SendUrgency.urgent,
      );
      return;
    }
    if (!_incoming.containsKey(key)) {
      final Object? rawNote = m.body['m'];
      String? note = rawNote is String ? sanitizeName(rawNote) : null;
      if (note != null && note.length > maxNoteLength) {
        note = note.substring(0, maxNoteLength);
      }
      final IncomingPing ping = IncomingPing(
        id: id,
        kind: kind,
        fromId: m.senderId,
        fromName: _members[m.senderId]?.name ?? m.senderId,
        receivedAt: _clock(),
        note: (note == null || note.isEmpty) ? null : note,
      );
      _incoming[key] = ping;
      if (!_pingAlerts.isClosed) _pingAlerts.add(ping);
    }
    // Always (re)acknowledge: the sender retries until it hears this.
    await _send(
      MessageKind.receipt,
      <String, Object?>{'id': id, 'for': 'ping'},
      to: <String>{m.senderId},
      urgency: SendUrgency.urgent,
    );
    // If we already answered, the answer may have been lost: resend it.
    final _PendingReply? pending = _pendingReplies[key];
    if (pending != null) await _sendReply(pending);
  }

  void _onReceipt(SecureMessage m) {
    final String? id = _idFrom(m.body['id']);
    if (id == null) return;
    if (m.body['for'] == 'reply') {
      _pendingReplies.remove(_incomingKey(m.senderId, id));
      return;
    }
    if (m.body['for'] == 'safe') {
      final _PendingSafe? safe = _pendingSafe[id];
      if (safe != null && safe.to.remove(m.senderId) && safe.to.isEmpty) {
        _pendingSafe.remove(id);
      }
      return;
    }
    final OutgoingPing? p = _outgoing[id];
    final RecipientStatus? r = p?.recipients[m.senderId];
    if (p == null || r == null) return;
    if (r.state == DeliveryState.sending ||
        r.state == DeliveryState.unreachable) {
      _outgoing[id] = p.copyWith(
        recipients: <String, RecipientStatus>{
          ...p.recipients,
          m.senderId: r.copyWith(
            state: DeliveryState.delivered,
            updatedAt: _clock(),
          ),
        },
      );
    }
  }

  Future<void> _onReply(SecureMessage m) async {
    final String? id = _idFrom(m.body['id']);
    final PingResponse? response = PingResponse.fromWire(m.body['r']);
    if (id == null || response == null) return;
    await _send(
      MessageKind.receipt,
      <String, Object?>{'id': id, 'for': 'reply'},
      to: <String>{m.senderId},
      urgency: SendUrgency.urgent,
    );
    final OutgoingPing? p = _outgoing[id];
    final RecipientStatus? r = p?.recipients[m.senderId];
    if (p == null || r == null) return;
    _outgoing[id] = p.copyWith(
      recipients: <String, RecipientStatus>{
        ...p.recipients,
        m.senderId: r.copyWith(
          state: DeliveryState.answered,
          response: response,
          updatedAt: _clock(),
        ),
      },
    );
  }

  // ── Outgoing plumbing ──────────────────────────────────────────────────

  Future<void> _hello({String? to}) async {
    if (_stopped) return;
    final DateTime now = _clock();
    if (to != null) {
      final DateTime? last = _lastHelloTo[to];
      if (last != null && now.difference(last) < const Duration(seconds: 5)) {
        return;
      }
      _lastHelloTo[to] = now;
    }
    await _send(
      MessageKind.hello,
      <String, Object?>{'n': displayName},
      to: to == null ? const <String>{} : <String>{to},
      urgency: to == null ? SendUrgency.announce : SendUrgency.normal,
    );
  }

  Future<void> _sendPingFrame(OutgoingPing p) async {
    final Set<String> pending = p.recipients.values
        .where((RecipientStatus r) => r.state == DeliveryState.sending)
        .map((RecipientStatus r) => r.peerId)
        .toSet();
    if (pending.isEmpty) return;
    await _send(
      MessageKind.ping,
      <String, Object?>{
        'id': p.id,
        'k': p.kind.wire,
        if (p.note != null) 'm': p.note,
      },
      to: pending,
      urgency: SendUrgency.urgent,
    );
  }

  Future<void> _sendReply(_PendingReply r) async {
    r.attempts++;
    await _send(
      MessageKind.reply,
      <String, Object?>{'id': r.pingId, 'r': r.response.wire},
      to: <String>{r.toId},
      urgency: SendUrgency.urgent,
    );
  }

  Future<void> _sendSafe(_PendingSafe s) async {
    s.attempts++;
    await _send(
      MessageKind.ping,
      <String, Object?>{'id': s.pingId, 'k': PingKind.sos.wire, 'x': true},
      to: s.to,
      urgency: SendUrgency.urgent,
    );
  }

  Future<void> _retry() async {
    if (_stopped) return;
    bool changed = false;
    for (final OutgoingPing p in _outgoing.values.toList()) {
      if (p.cancelled) continue;
      final int budget = p.kind == PingKind.sos ? sosAttempts : checkInAttempts;
      final Map<String, RecipientStatus> next = <String, RecipientStatus>{};
      bool any = false;
      for (final MapEntry<String, RecipientStatus> e in p.recipients.entries) {
        RecipientStatus r = e.value;
        if (r.state == DeliveryState.sending) {
          r = r.copyWith(attempts: r.attempts + 1);
          if (r.attempts >= budget) {
            r = r.copyWith(
              state: DeliveryState.unreachable,
              updatedAt: _clock(),
            );
            changed = true;
          } else {
            any = true;
          }
        }
        next[e.key] = r;
      }
      _outgoing[p.id] = p.copyWith(recipients: next);
      if (any) await _sendPingFrame(_outgoing[p.id]!);
    }
    for (final MapEntry<String, _PendingReply> e
        in _pendingReplies.entries.toList()) {
      if (e.value.attempts >= replyAttempts) {
        _pendingReplies.remove(e.key);
      } else {
        await _sendReply(e.value);
      }
    }
    for (final _PendingSafe s in _pendingSafe.values.toList()) {
      if (s.attempts >= sosAttempts) {
        _pendingSafe.remove(s.pingId);
      } else {
        await _sendSafe(s);
      }
    }
    if (changed) _notify();
  }

  Future<void> _broadcast(MessageKind kind, Map<String, Object?> body) =>
      _send(kind, body);

  Future<void> _send(
    MessageKind kind,
    Map<String, Object?> body, {
    Set<String> to = const <String>{},
    SendUrgency urgency = SendUrgency.normal,
  }) async {
    final List<MessageTransport> up = _transports
        .where((MessageTransport t) => t.status.isUp)
        .toList();
    if (up.isEmpty) {
      if (!_reportedNoTransport && urgency == SendUrgency.urgent) {
        _reportedNoTransport = true;
        _emitError(const NoTransportError());
      }
      return;
    }
    _reportedNoTransport = false;
    final Uint8List frame;
    try {
      frame = await _messenger.seal(kind, body, to: to);
    } on StateError {
      return; // Wiped during shutdown.
    }
    // Same frame on every radio; receivers drop the duplicate.
    await Future.wait(
      up.map((MessageTransport t) async {
        try {
          await t.send(frame, to: to, urgency: urgency);
        } catch (e) {
          _emitError(TransportError(t.label, '$e'));
        }
      }),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  OutgoingPing _withNewMembers(OutgoingPing p) {
    final Map<String, RecipientStatus> r = <String, RecipientStatus>{
      ...p.recipients,
    };
    for (final SessionMember m in _members.values) {
      r.putIfAbsent(
        m.peerId,
        () => RecipientStatus(peerId: m.peerId, name: m.name),
      );
    }
    return p.copyWith(recipients: r);
  }

  void _renameInPings(String peerId, String name) {
    for (final OutgoingPing p in _outgoing.values.toList()) {
      final RecipientStatus? r = p.recipients[peerId];
      if (r == null || r.name == name) continue;
      _outgoing[p.id] = p.copyWith(
        recipients: <String, RecipientStatus>{
          ...p.recipients,
          peerId: RecipientStatus(
            peerId: peerId,
            name: name,
            state: r.state,
            response: r.response,
            updatedAt: r.updatedAt,
            attempts: r.attempts,
          ),
        },
      );
    }
  }

  void _onTransportStatus() {
    final bool up = anyTransportUp;
    if (up && !_anyUp) {
      _reportedNoTransport = false;
      // A radio just came back: re-announce and flush pending pings now
      // rather than waiting for the next tick. Status changes while a
      // radio stays up (a peer appearing or leaving changes the reachable
      // count) are not announcements: with a group joining at once they
      // would make every phone broadcast hello once per newcomer.
      unawaited(_hello());
      for (final OutgoingPing p in _outgoing.values) {
        if (!p.cancelled) unawaited(_sendPingFrame(p));
      }
    }
    _anyUp = up;
    _notify();
  }

  String? _validateNote(String? note) {
    if (note == null) return null;
    final String clean = sanitizeName(note);
    if (clean.isEmpty) return null;
    if (clean.length > maxNoteLength) {
      throw const InvalidInputError(
        'Message',
        'must be at most $maxNoteLength characters',
      );
    }
    return clean;
  }

  String _newId() => String.fromCharCodes(
    List<int>.generate(
      8,
      (_) => SessionCodec.alphabet.codeUnitAt(
        _random.nextInt(SessionCodec.alphabet.length),
      ),
    ),
  );

  static String? _idFrom(Object? v) =>
      v is String && v.length == 8 && SessionCodec.alphabet.contains(v[0])
      ? v
      : null;

  static String _incomingKey(String from, String id) => '$from:$id';

  void _ensureRunning() {
    if (_stopped) throw StateError('Session has ended');
  }

  void _emitError(EchoError e) {
    if (!_errors.isClosed) _errors.add(e);
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}

class _PendingSafe {
  _PendingSafe(this.pingId, this.to);
  final String pingId;

  /// Recipients that have not confirmed yet.
  final Set<String> to;
  int attempts = 0;
}

class _PendingReply {
  _PendingReply(this.toId, this.pingId, this.response);
  final String toId;
  final String pingId;
  final PingResponse response;
  int attempts = 0;
}
