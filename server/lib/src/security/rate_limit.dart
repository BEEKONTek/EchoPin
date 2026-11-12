// RATE LIMITS: "at most N of these per window" for any key (an IP, an
// email, an account). Two implementations of one interface:
//
// - DbRateLimiter (production): counters live in PostgreSQL, so they
//   survive restarts and every server instance shares them. One UPSERT
//   per check, atomic, so parallel requests can't slip through.
// - RateLimiter (tests, tools): in memory, per process.

import '../db/database.dart';

/// Records a hit for [key] and says how long to wait, or null if allowed.
abstract interface class Limiter {
  Future<Duration?> hit(
    String key, {
    required int limit,
    required Duration window,
  });

  /// Forgets a key, e.g. after a successful sign-in or an admin unlock.
  Future<void> reset(String key);
}

/// Fixed-window counters in the `rate_hits` table.
///
/// A fixed window lets a burst of up to 2 × limit straddle a boundary;
/// for the limits used here (attempts per minutes) that is harmless, and
/// it keeps each check to one statement with no read-modify-write race.
class DbRateLimiter implements Limiter {
  DbRateLimiter(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Db _db;
  final DateTime Function() _clock;

  @override
  Future<Duration?> hit(
    String key, {
    required int limit,
    required Duration window,
  }) async {
    final DateTime now = _clock().toUtc();
    final int w = window.inMilliseconds;
    final DateTime start = DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch ~/ w * w,
      isUtc: true,
    );
    final Row r = (await _db.one(
      '''insert into rate_hits (key, window_start, hits) values (@k, @s, 1)
         on conflict (key) do update set
           hits = case when rate_hits.window_start = @s then rate_hits.hits + 1 else 1 end,
           window_start = @s
         returning hits''',
      <String, Object?>{'k': key, 's': start},
    ))!;
    if ((r['hits'] as int) <= limit) return null;
    return start.add(window).difference(now);
  }

  @override
  Future<void> reset(String key) => _db.execute(
    'delete from rate_hits where key = @k',
    <String, Object?>{'k': key},
  );

  /// Drops counters whose window ended long ago (run by the retention job).
  static Future<int> prune(Db db, DateTime now) => db.execute(
    'delete from rate_hits where window_start < @t',
    <String, Object?>{'t': now.subtract(const Duration(days: 1))},
  );
}

/// In-memory sliding-window limiter. Per process and lost on restart, so
/// the server uses [DbRateLimiter]; this one is for tests and tools.
class RateLimiter implements Limiter {
  RateLimiter({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _hits = <String, List<DateTime>>{};
  int _calls = 0;

  @override
  Future<Duration?> hit(
    String key, {
    required int limit,
    required Duration window,
  }) async {
    final DateTime now = _clock();
    if (++_calls % 1000 == 0) _prune(now);
    final List<DateTime> list = _hits.putIfAbsent(key, () => <DateTime>[]);
    list.removeWhere((DateTime t) => now.difference(t) >= window);
    if (list.length >= limit) {
      return window - now.difference(list.first);
    }
    list.add(now);
    return null;
  }

  @override
  Future<void> reset(String key) async => _hits.remove(key);

  void _prune(DateTime now) {
    _hits.removeWhere(
      (_, List<DateTime> v) =>
          v.isEmpty || now.difference(v.last) > const Duration(hours: 2),
    );
  }
}
