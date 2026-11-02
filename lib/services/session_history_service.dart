import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_pin/models/session_summary.dart';

/// Persists the last [_maxEntries] sessions to disk for the "recent sessions"
/// list on HomeScreen. Only session metadata is stored — never peers or
/// positions.
class SessionHistoryService {
  static const String _kHistory = 'echo_pin.session_history';
  static const int _maxEntries = 20;

  Future<List<SessionSummary>> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_kHistory);
    if (raw == null || raw.isEmpty) return <SessionSummary>[];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (dynamic e) => SessionSummary.fromJson(e as Map<String, dynamic>),
          )
          .toList();
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

  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHistory);
  }

  Future<void> _persist(List<SessionSummary> list) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(
      list.map((SessionSummary s) => s.toJson()).toList(),
    );
    await prefs.setString(_kHistory, encoded);
  }
}
