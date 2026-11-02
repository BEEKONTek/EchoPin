import 'package:flutter/services.dart';

/// Thin wrapper around [HapticFeedback] with a user-toggle hook.
///
/// The `isEnabled` callback is queried on every call, so callers can flip the
/// setting at runtime without re-wiring the service.
class HapticService {
  HapticService({required this.isEnabled});

  final bool Function() isEnabled;

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
}
