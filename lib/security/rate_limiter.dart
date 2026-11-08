/// Per-key token bucket.
///
/// Defaults follow docs/ARCHITECTURE.md: 5 tokens, one refilled every
/// 500 ms, i.e. a sustained 2 messages/s per peer with small bursts.
class RateLimiter {
  RateLimiter({
    this.capacity = 5,
    this.refillEvery = const Duration(milliseconds: 500),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int capacity;
  final Duration refillEvery;
  final DateTime Function() _clock;
  final Map<String, _Bucket> _buckets = <String, _Bucket>{};

  /// Consumes a token for [key]; false when the bucket is empty.
  bool tryAcquire(String key) {
    final DateTime now = _clock();
    final _Bucket b = _buckets.putIfAbsent(
      key,
      () => _Bucket(capacity.toDouble(), now),
    );
    final double refill =
        now.difference(b.updated).inMicroseconds / refillEvery.inMicroseconds;
    b.tokens = (b.tokens + refill).clamp(0, capacity.toDouble());
    b.updated = now;
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  }

  /// Time until [key] has a token again.
  Duration retryAfter(String key) {
    final _Bucket? b = _buckets[key];
    if (b == null || b.tokens >= 1) return Duration.zero;
    final double missing = 1 - b.tokens;
    return Duration(
      microseconds: (missing * refillEvery.inMicroseconds).ceil(),
    );
  }

  void clear() => _buckets.clear();
}

class _Bucket {
  _Bucket(this.tokens, this.updated);
  double tokens;
  DateTime updated;
}
