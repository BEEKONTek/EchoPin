import 'dart:async';

import 'package:flutter/services.dart';

/// Thin wrapper around [HapticFeedback] with a user-toggle hook.
///
/// The `isEnabled` callback is queried on every call, so callers can flip the
/// setting at runtime without re-wiring the service.
class HapticService {
  HapticService({
    required this.isEnabled,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? ((Duration d) => Future<void>.delayed(d));

  final bool Function() isEnabled;
  final Future<void> Function(Duration) _delay;

  Future<void> light() async {
    if (!isEnabled()) return;
    await HapticFeedback.lightImpact();
  }

  Future<void> medium() async {
    if (!isEnabled()) return;
    await HapticFeedback.mediumImpact();
  }

  Future<void> heavy() async {
    if (!isEnabled()) return;
    await HapticFeedback.heavyImpact();
  }

  /// Three hard pulses: unmistakable even in a pocket.
  Future<void> sos() async {
    if (!isEnabled()) return;
    for (int i = 0; i < 3; i++) {
      await HapticFeedback.heavyImpact();
      if (i < 2) await _delay(const Duration(milliseconds: 180));
    }
  }
}
