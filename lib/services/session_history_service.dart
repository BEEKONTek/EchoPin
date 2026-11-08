import 'dart:convert';

import 'package:echo_pin/models/session_summary.dart';
import 'package:echo_pin/services/key_value_store.dart';
import 'package:echo_pin/services/prefs_kv_store.dart';

/// Persists the last [_maxEntries] sessions for the "recent sessions" tray
/// on the home screen. Only session metadata is stored, never peers or
/// positions.
///
/// Entries include the invite code, which is the session secret, so the
/// production wiring passes the OS-keystore-backed store chosen by
/// `Bootstrap`. The default (plain prefs) is for tests and fallbacks.
class SessionHistoryService {
  SessionHistoryService({KeyValueStore? kv}) : _kv = kv ?? PrefsKvStore();

  static const String _kHistory = 'echo_pin.session_history';
  static const int _maxEntries = 20;

  final KeyValueStore _kv;

  Future<List<SessionSummary>> load() async {
    final String? raw = await _kv.read(_kHistory);
    if (raw == null || raw.isEmpty) return <SessionSummary>[];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      final List<SessionSummary> out = <SessionSummary>[];
      for (final dynamic e in list) {
        try {
          out.add(SessionSummary.fromJson(e as Map<String, dynamic>));
        } catch (_) {
          // Skip one corrupt entry rather than losing the whole history.
        }
      }
      return out;
    } catch (_) {
      return <SessionSummary>[];
    }
  }

  /// Records (or bumps) a session. Newest first, capped at [_maxEntries].
  Future<void> record(SessionSummary summary) async {
    // Defensive copy: load() may return a fixed-size or unmodifiable list in
    // the future; record() must be free to mutate its working set.
    final List<SessionSummary> existing = List<SessionSummary>.of(await load());
    existing.removeWhere((SessionSummary s) => s.id == summary.id);
    existing.insert(0, summary);
    if (existing.length > _maxEntries) {
      existing.removeRange(_maxEntries, existing.length);
    }
    await _persist(existing);
  }

  Future<void> remove(String id) async {
    final List<SessionSummary> existing = List<SessionSummary>.of(await load())
      ..removeWhere((SessionSummary s) => s.id == id);
    await _persist(existing);
  }

  Future<void> clear() => _kv.delete(_kHistory);

  Future<void> _persist(List<SessionSummary> list) {
    return _kv.write(
      _kHistory,
      jsonEncode(list.map((SessionSummary s) => s.toJson()).toList()),
    );
  }
}
