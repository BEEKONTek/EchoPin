import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/security/rate_limiter.dart';
import 'package:echo_pin/security/replay_guard.dart';
import 'package:echo_pin/security/session_credentials.dart';
import 'package:echo_pin/security/session_identity.dart';
import 'package:echo_pin/security/wire.dart';
import 'package:flutter/foundation.dart';

/// Seals outgoing messages and opens incoming frames for one session.
///
/// Every incoming frame passes the same gauntlet, in this order, and is
/// dropped at the first failure:
///   1. structure, magic, version, session id (foreign traffic is ignored)
///   2. XChaCha20-Poly1305 decryption with the session key (membership)
///   3. Ed25519 signature by the embedded sender key (authenticity)
///   4. sender id == id derived from that key; id pinned to its first key
///   5. replay window (duplicates over two radios are silently dropped)
///   6. timestamp within [maxClockSkew]
///   7. per-sender rate limit, and the [maxMembers] cap for newcomers
///
/// Rejections are reported on [events] so the UI and admin log can react.
class SecureMessenger {
  SecureMessenger({
    required this.credentials,
    required this.identity,
    this.maxClockSkew = const Duration(minutes: 2),
    this.maxMembers = 20,
    RateLimiter? limiter,
    ReplayGuard? replayGuard,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _limiter = limiter ?? RateLimiter(clock: clock),
       _replay = replayGuard ?? ReplayGuard();

  static final Xchacha20 _aead = Xchacha20.poly1305Aead();

  final SessionCredentials credentials;
  final SessionIdentity identity;
  final Duration maxClockSkew;

  /// Including this device.
  final int maxMembers;

  final DateTime Function() _clock;
  final RateLimiter _limiter;
  final ReplayGuard _replay;
  final Map<String, List<int>> _pinned = <String, List<int>>{};
  final Map<String, DateTime> _lastFloodReport = <String, DateTime>{};
  final Set<String> _reportedFull = <String>{};
  final StreamController<EchoError> _events =
      StreamController<EchoError>.broadcast();
  final Map<SecurityProblem, int> _rejections = <SecurityProblem, int>{};
  int _counter = 0;
  int _accepted = 0;
  int _sent = 0;

  Stream<EchoError> get events => _events.stream;
  Map<SecurityProblem, int> get rejections =>
      Map<SecurityProblem, int>.unmodifiable(_rejections);
  int get acceptedCount => _accepted;
  int get sentCount => _sent;

  /// Peers whose key has been pinned (excluding this device).
  Set<String> get knownPeers => Set<String>.unmodifiable(_pinned.keys);

  List<int>? keyFor(String peerId) => _pinned[peerId];

  /// Pins [peerId] to [key] as if seen first. Lets tests simulate the
  /// id-collision attack that pinning defends against.
  @visibleForTesting
  void debugPin(String peerId, List<int> key) => _pinned[peerId] = key;

  Future<Uint8List> seal(
    MessageKind kind,
    Map<String, Object?> body, {
    Set<String> to = const <String>{},
  }) async {
    if (to.length > Wire.maxRecipients) {
      throw ArgumentError('At most ${Wire.maxRecipients} recipients');
    }
    final List<int> bodyBytes = utf8.encode(jsonEncode(body));
    if (bodyBytes.length > Wire.maxBodyLength) {
      throw ArgumentError('Message body too large (${bodyBytes.length} B)');
    }
    final Uint8List header = Wire.header(credentials.sessionId);

    final BytesBuilder inner = BytesBuilder()
      ..addByte(kind.code)
      ..add(identity.publicKey);
    writeU64(inner, ++_counter);
    writeU64(inner, _clock().millisecondsSinceEpoch);
    inner.addByte(to.length);
    for (final String r in to) {
      final List<int> id = ascii.encode(r);
      if (id.length != Wire.peerIdLength) {
        throw ArgumentError.value(r, 'recipient', 'not a peer id');
      }
      inner.add(id);
    }
    inner
      ..addByte(bodyBytes.length >> 8)
      ..addByte(bodyBytes.length & 0xff)
      ..add(bodyBytes);
    final Uint8List unsigned = inner.toBytes();
    final List<int> signature = await identity.sign(<int>[
      ...header,
      ...unsigned,
    ]);

    final SecretBox box = await _aead.encrypt(
      <int>[...unsigned, ...signature],
      secretKey: credentials.key,
      nonce: _aead.newNonce(),
      aad: header,
    );
    _sent++;
    return Uint8List.fromList(<int>[
      ...header,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Returns the verified message, or null when the frame was dropped.
  Future<SecureMessage?> open(Uint8List frame) async {
    if (frame.length < Wire.headerLength + 2 ||
        frame[0] != Wire.magic[0] ||
        frame[1] != Wire.magic[1]) {
      return null; // Not EchoPin traffic.
    }
    if (frame[2] != Wire.version) {
      return _reject(SecurityProblem.malformed, detail: 'version ${frame[2]}');
    }
    final String sid = ascii.decode(
      frame.sublist(4, Wire.headerLength),
      allowInvalid: true,
    );
    if (sid != credentials.sessionId) return null; // Another session.
    if (frame.length < Wire.minFrame || frame.length > Wire.maxFrame) {
      return _reject(SecurityProblem.malformed, detail: '${frame.length} B');
    }

    final Uint8List header = Uint8List.sublistView(frame, 0, Wire.headerLength);
    const int nonceEnd = Wire.headerLength + Wire.nonceLength;
    final int macStart = frame.length - Wire.macLength;
    final List<int> clear;
    try {
      clear = await _aead.decrypt(
        SecretBox(
          Uint8List.sublistView(frame, nonceEnd, macStart),
          nonce: Uint8List.sublistView(frame, Wire.headerLength, nonceEnd),
          mac: Mac(Uint8List.sublistView(frame, macStart)),
        ),
        secretKey: credentials.key,
        aad: header,
      );
    } on SecretBoxAuthenticationError {
      return _reject(SecurityProblem.undecryptable);
    }

    final _Inner? inner = _Inner.parse(Uint8List.fromList(clear));
    if (inner == null) return _reject(SecurityProblem.malformed);

    final String senderId = peerIdForKey(inner.senderKey);
    if (senderId == identity.peerId) return null; // Our own echo.

    final bool signed = await SessionIdentity.verify(
      <int>[...header, ...inner.signedPart],
      inner.signature,
      inner.senderKey,
    );
    if (!signed) {
      return _reject(SecurityProblem.badSignature, peerId: senderId);
    }

    final List<int>? pinned = _pinned[senderId];
    if (pinned != null && !_equal(pinned, inner.senderKey)) {
      return _reject(SecurityProblem.impersonation, peerId: senderId);
    }
    if (pinned == null && _pinned.length >= maxMembers - 1) {
      if (_reportedFull.add(senderId)) {
        _emit(SessionFullError(maxMembers));
      }
      return null;
    }

    switch (_replay.check(senderId, inner.counter)) {
      case ReplayVerdict.duplicate:
        return null;
      case ReplayVerdict.tooOld:
        return _reject(SecurityProblem.replay, peerId: senderId);
      case ReplayVerdict.fresh:
        break;
    }

    final DateTime sentAt = DateTime.fromMillisecondsSinceEpoch(
      inner.timestampMs,
    );
    if (sentAt.difference(_clock()).abs() > maxClockSkew) {
      return _reject(
        SecurityProblem.stale,
        peerId: senderId,
        detail: 'clock off by ${sentAt.difference(_clock()).inSeconds} s',
      );
    }

    if (!_limiter.tryAcquire(senderId)) {
      final DateTime now = _clock();
      final DateTime? last = _lastFloodReport[senderId];
      if (last == null || now.difference(last) > const Duration(seconds: 10)) {
        _lastFloodReport[senderId] = now;
        return _reject(SecurityProblem.flooding, peerId: senderId);
      }
      _count(SecurityProblem.flooding);
      return null;
    }

    _pinned[senderId] = List<int>.unmodifiable(inner.senderKey);
    _accepted++;
    return SecureMessage(
      kind: inner.kind,
      senderId: senderId,
      senderKey: inner.senderKey,
      counter: inner.counter,
      sentAt: sentAt,
      recipients: inner.recipients,
      body: inner.body,
    );
  }

  SecureMessage? _reject(
    SecurityProblem problem, {
    String? peerId,
    String detail = '',
  }) {
    _count(problem);
    _emit(SecurityError(problem, peerId: peerId, detail: detail));
    return null;
  }

  void _count(SecurityProblem p) => _rejections[p] = (_rejections[p] ?? 0) + 1;

  void _emit(EchoError e) {
    if (!_events.isClosed) _events.add(e);
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Future<void> dispose() async {
    _pinned.clear();
    _replay.clear();
    _limiter.clear();
    unawaited(_events.close());
  }
}

class _Inner {
  _Inner({
    required this.kind,
    required this.senderKey,
    required this.counter,
    required this.timestampMs,
    required this.recipients,
    required this.body,
    required this.signedPart,
    required this.signature,
  });

  final MessageKind kind;
  final List<int> senderKey;
  final int counter;
  final int timestampMs;
  final Set<String> recipients;
  final Map<String, Object?> body;
  final Uint8List signedPart;
  final Uint8List signature;

  static _Inner? parse(Uint8List b) {
    try {
      int o = 0;
      final MessageKind? kind = MessageKind.fromCode(b[o++]);
      if (kind == null) return null;
      final Uint8List key = Uint8List.sublistView(b, o, o + Wire.keyLength);
      o += Wire.keyLength;
      final int counter = readU64(b, o);
      o += 8;
      final int ts = readU64(b, o);
      o += 8;
      final int n = b[o++];
      if (n > Wire.maxRecipients) return null;
      final Set<String> recipients = <String>{};
      for (int i = 0; i < n; i++) {
        recipients.add(ascii.decode(b.sublist(o, o + Wire.peerIdLength)));
        o += Wire.peerIdLength;
      }
      final int len = (b[o] << 8) | b[o + 1];
      o += 2;
      if (len > Wire.maxBodyLength) return null;
      final Object? decoded = jsonDecode(utf8.decode(b.sublist(o, o + len)));
      o += len;
      if (decoded is! Map<String, dynamic>) return null;
      if (b.length - o != Wire.signatureLength) return null;
      return _Inner(
        kind: kind,
        senderKey: key,
        counter: counter,
        timestampMs: ts,
        recipients: recipients,
        body: decoded,
        signedPart: Uint8List.sublistView(b, 0, o),
        signature: Uint8List.sublistView(b, o),
      );
    } catch (_) {
      return null;
    }
  }
}
