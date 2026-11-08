/// Result of checking a message counter against a sender's window.
enum ReplayVerdict {
  /// New message: accept.
  fresh,

  /// Same counter seen before, e.g. the same frame over BLE and Wi-Fi.
  /// Benign: drop silently.
  duplicate,

  /// Older than the window: cannot be told apart from a replay.
  tooOld,
}

/// Per-sender sliding replay window (as in IPsec / DTLS, RFC 6347 §4.1.2.6).
///
/// Accepts any counter above the highest seen, and out-of-order counters up
/// to [window] below it that have not been seen. Out-of-order delivery is
/// normal here because the same session runs over two radios.
class ReplayGuard {
  ReplayGuard({this.window = 64});

  final int window;
  final Map<String, _Window> _bySender = <String, _Window>{};

  ReplayVerdict check(String sender, int counter) {
    final _Window w = _bySender.putIfAbsent(sender, _Window.new);
    if (counter <= 0) return ReplayVerdict.tooOld;
    if (counter > w.highest) {
      w.highest = counter;
      w.seen.add(counter);
      w.seen.removeWhere((int c) => c <= counter - window);
      return ReplayVerdict.fresh;
    }
    if (counter <= w.highest - window) return ReplayVerdict.tooOld;
    if (!w.seen.add(counter)) return ReplayVerdict.duplicate;
    return ReplayVerdict.fresh;
  }

  void forget(String sender) => _bySender.remove(sender);
  void clear() => _bySender.clear();
}

class _Window {
  int highest = 0;
  final Set<int> seen = <int>{};
}
