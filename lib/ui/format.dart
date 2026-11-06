/// Display helpers shared by every screen.
abstract final class Fmt {
  static String distance(double meters) {
    if (meters < 1) return '< 1 m';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  static String ago(DateTime t, [DateTime? now]) {
    final Duration d = (now ?? DateTime.now()).difference(t);
    if (d.inSeconds < 10) return 'just now';
    if (d.inMinutes < 1) return '${d.inSeconds} s ago';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  static String initials(String name) {
    final List<String> parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((String p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.characters.take(2).toUpperCase();
    }
    return '${parts.first.characters.first}${parts.last.characters.first}'
        .toUpperCase();
  }

  /// Seconds remaining, for countdowns.
  static String remaining(Duration d) {
    if (d.inHours >= 1) return '${d.inHours} h ${d.inMinutes % 60} min';
    if (d.inMinutes >= 1) return '${d.inMinutes} min';
    return '${d.inSeconds.clamp(0, 59)} s';
  }
}

extension on String {
  _Chars get characters => _Chars(this);
}

/// Minimal grapheme-safe-ish helpers without the `characters` package:
/// works on runes so emoji and accented letters are not split mid-code-unit.
class _Chars {
  _Chars(this.s);
  final String s;

  String get first => s.isEmpty ? '' : String.fromCharCode(s.runes.first);

  String take(int n) => String.fromCharCodes(s.runes.take(n));
}
