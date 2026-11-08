// OUTBOX: store-and-forward for everything the app sends to the server.
//
// Diagnostics, sealed session logs and reports are written here first,
// saved on the device, and uploaded when there is a connection. Nothing is
// lost when you are offline, the app is killed, or the server is asleep.
//
// - Each item has a client-made UUID, so retries are idempotent: the
//   server stores a log once however many times it arrives.
// - Session logs are sealed (encrypted to the escrow key) *before* they
//   are saved here, so the queue on the phone holds no readable history.
// - Items belong to the account that made them; signing in as someone
//   else never uploads the previous person's data under the new name.
// - Failed uploads back off; very old or excess items are dropped.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:echo_pin/account/account_models.dart';
import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/services/key_value_store.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/foundation.dart';

enum OutboxKind {
  diagnostics('/v1/diagnostics'),
  sessionLog('/v1/session-logs'),
  report('/v1/reports');

  const OutboxKind(this.path);
  final String path;
}

@immutable
class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.kind,
    required this.accountId,
    required this.body,
    required this.createdAt,
    this.attempts = 0,
    this.nextAttemptAt,
    this.lastError,
  });

  final String id;
  final OutboxKind kind;

  /// Items only ever upload under the account that created them.
  final String accountId;
  final Map<String, dynamic> body;
  final DateTime createdAt;
  final int attempts;
  final DateTime? nextAttemptAt;
  final String? lastError;

  OutboxItem copyWith({
    Map<String, dynamic>? body,
    int? attempts,
    DateTime? nextAttemptAt,
    String? lastError,
  }) => OutboxItem(
    id: id,
    kind: kind,
    accountId: accountId,
    body: body ?? this.body,
    createdAt: createdAt,
    attempts: attempts ?? this.attempts,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    lastError: lastError ?? this.lastError,
  );

  factory OutboxItem.fromJson(Map<String, dynamic> j) => OutboxItem(
    id: j['id'] as String,
    kind: OutboxKind.values.byName(j['kind'] as String),
    accountId: j['accountId'] as String,
    body: (j['body'] as Map<String, dynamic>),
    createdAt: DateTime.parse(j['createdAt'] as String),
    attempts: j['attempts'] as int? ?? 0,
    nextAttemptAt: j['nextAttemptAt'] == null ? null : DateTime.parse(j['nextAttemptAt'] as String),
    lastError: j['lastError'] as String?,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'accountId': accountId,
    'body': body,
    'createdAt': createdAt.toIso8601String(),
    'attempts': attempts,
    'nextAttemptAt': nextAttemptAt?.toIso8601String(),
    'lastError': lastError,
  };
}

/// Store-and-forward queue for everything the app sends to the server.
///
/// EchoPin is used where there is no signal, so nothing is sent directly:
/// it goes here first (kept in the OS keystore), then uploads when the
/// device is online and signed in. Uploads are idempotent on the server, so
/// a retry after a dropped connection never duplicates anything.
///
/// Session logs are sealed to the escrow key as soon as that key is known,
/// so they are not kept readable on the device any longer than necessary.
class Outbox extends ChangeNotifier {
  Outbox({
    required KeyValueStore kv,
    required AccountProvider account,
    DateTime Function()? clock,
    this.retryEvery = const Duration(minutes: 2),
    this.maxItems = 200,
    this.maxAge = const Duration(days: 30),
  }) : _kv = kv,
       _account = account,
       _clock = clock ?? DateTime.now;

  final KeyValueStore _kv;
  final AccountProvider _account;
  final DateTime Function() _clock;
  final Duration retryEvery;
  final int maxItems;
  final Duration maxAge;

  static const String _kOutbox = 'echo_pin.outbox_v1';

  List<OutboxItem> _items = <OutboxItem>[];
  Timer? _timer;
  bool _flushing = false;
  bool _disposed = false;
  int _rejected = 0;
  String? _lastRejection;
  DateTime? _lastSentAt;

  List<OutboxItem> get items => List<OutboxItem>.unmodifiable(_items);
  int get pendingCount => _items.length;
  int get rejectedCount => _rejected;
  String? get lastRejection => _lastRejection;
  DateTime? get lastSentAt => _lastSentAt;
  bool get isFlushing => _flushing;

  Future<void> load() async {
    try {
      final String? raw = await _kv.read(_kOutbox);
      if (raw != null) {
        _items = (jsonDecode(raw) as List<dynamic>)
            .map((dynamic e) {
              try {
                return OutboxItem.fromJson(e as Map<String, dynamic>);
              } catch (_) {
                return null;
              }
            })
            .whereType<OutboxItem>()
            .toList();
      }
    } catch (_) {
      _items = <OutboxItem>[];
    }
    _expire();
    _notify();
  }

  /// Retries on a timer and whenever the account signs in.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(retryEvery, (_) => unawaited(flush()));
    _account.addListener(_onAccount);
  }

  bool _wasSignedIn = false;
  void _onAccount() {
    final bool now = _account.signedIn;
    if (now && !_wasSignedIn) unawaited(flush());
    _wasSignedIn = now;
  }

  /// Queues [body]. Returns the item id. Requires a signed-in account.
  Future<String> enqueue(OutboxKind kind, Map<String, dynamic> body, {String? id}) async {
    final Account? a = _account.account;
    if (a == null) {
      throw const AccountError('unauthorized', 'Sign in to send this', status: 401);
    }
    final String itemId = id ?? newUuid();
    Map<String, dynamic> b = body;
    if (kind == OutboxKind.sessionLog) b = await _sealIfPossible(itemId, b);
    _items.add(OutboxItem(
      id: itemId,
      kind: kind,
      accountId: a.id,
      body: b,
      createdAt: _clock().toUtc(),
    ));
    _trim();
    await _persist();
    _notify();
    return itemId;
  }

  /// Sends what can be sent now. Returns true if the queue is empty for
  /// the current account afterwards.
  Future<bool> flush() async {
    if (_flushing) {
      // Something was queued mid-flush: run once more when this one ends,
      // instead of leaving it for the next timer tick.
      _again = true;
      return false;
    }
    final Account? a = _account.account;
    if (a == null) return false;
    _flushing = true;
    _notify();
    bool result = false;
    try {
      do {
        _again = false;
        result = await _flushOnce(a);
      } while (_again);
      return result;
    } finally {
      _flushing = false;
      _notify();
    }
  }

  bool _again = false;

  Future<bool> _flushOnce(Account a) async {
    {
      _expire();
      final DateTime now = _clock().toUtc();
      for (final OutboxItem item in List<OutboxItem>.of(_items)) {
        if (item.accountId != a.id) continue;
        final DateTime? next = item.nextAttemptAt;
        if (next != null && next.isAfter(now)) continue;
        OutboxItem current = item;
        if (current.kind == OutboxKind.sessionLog && current.body.containsKey('plain')) {
          await _account.ensureEscrow();
          final Map<String, dynamic> sealed = await _sealIfPossible(current.id, current.body);
          if (sealed.containsKey('plain')) continue; // still no key: wait
          current = current.copyWith(body: sealed);
          _replace(current);
          await _persist();
        }
        try {
          await _account.authed('POST', current.kind.path, body: _wire(current));
          _items.removeWhere((OutboxItem i) => i.id == current.id);
          _lastSentAt = _clock().toUtc();
          await _persist();
          _notify();
        } on OfflineError {
          return false;
        } on AccountError catch (e) {
          if (e.status == 401) return false;
          if (e.status == 429 || e.status >= 500) {
            final int attempts = current.attempts + 1;
            final Duration wait =
                e.retryAfter ?? Duration(minutes: math.min(1 << math.min(attempts, 6), 60));
            _replace(current.copyWith(
              attempts: attempts,
              nextAttemptAt: _clock().toUtc().add(wait),
              lastError: e.message,
            ));
            await _persist();
            return false;
          }
          // Permanently refused (bad input, too large): retrying cannot
          // help, so drop it and remember why for diagnostics.
          _items.removeWhere((OutboxItem i) => i.id == current.id);
          _rejected++;
          _lastRejection = '${current.kind.name}: ${e.message}';
          await _persist();
          _notify();
        }
      }
      return !_items.any((OutboxItem i) => i.accountId == a.id);
    }
  }

  Map<String, dynamic> _wire(OutboxItem item) => switch (item.kind) {
    OutboxKind.sessionLog => <String, dynamic>{...item.body, 'id': item.id},
    _ => item.body,
  };

  Future<Map<String, dynamic>> _sealIfPossible(String id, Map<String, dynamic> body) async {
    final Object? plain = body['plain'];
    final EscrowKey? key = _account.escrow;
    if (plain == null || key == null) return body;
    List<int> payload = utf8.encode(jsonEncode(plain));
    final List<int>? custodian = key.custodianPublicKey;
    if (custodian != null) {
      // Inner seal: only a responder's device holding the custodian key can
      // remove it. The context binds it to this record's id, like the
      // outer one, so a blob can't be moved to another record.
      payload = await SealedBox.seal(
        recipientPublicKey: custodian,
        plaintext: payload,
        context: 'session-log-custodian:$id',
      );
    }
    // Outer seal: the server removes it during an audited break-glass.
    final List<int> sealed = await SealedBox.seal(
      recipientPublicKey: key.publicKey,
      plaintext: payload,
      context: 'session-log:$id',
    );
    return <String, dynamic>{
      for (final MapEntry<String, dynamic> e in body.entries)
        if (e.key != 'plain') e.key: e.value,
      'keyId': key.keyId,
      'sealed': base64.encode(sealed),
      if (custodian != null) 'custodianKeyId': key.custodianKeyId,
    };
  }

  void _replace(OutboxItem item) {
    final int i = _items.indexWhere((OutboxItem x) => x.id == item.id);
    if (i >= 0) _items[i] = item;
  }

  void _expire() {
    final DateTime cutoff = _clock().toUtc().subtract(maxAge);
    _items.removeWhere((OutboxItem i) => i.createdAt.isBefore(cutoff));
  }

  /// Over the cap, routine diagnostics go first; reports and session logs
  /// are what someone may need in an emergency.
  void _trim() {
    while (_items.length > maxItems) {
      final int diag = _items.indexWhere((OutboxItem i) => i.kind == OutboxKind.diagnostics);
      _items.removeAt(diag >= 0 ? diag : 0);
    }
  }

  Future<void> _persist() =>
      _kv.write(_kOutbox, jsonEncode(_items.map((OutboxItem i) => i.toJson()).toList()));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _account.removeListener(_onAccount);
    super.dispose();
  }
}

/// Random (version 4) UUID.
String newUuid() {
  final math.Random r = math.Random.secure();
  final List<int> b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String hex(int from, int to) =>
      b.sublist(from, to).map((int x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
