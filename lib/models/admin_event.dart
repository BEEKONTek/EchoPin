import 'package:flutter/foundation.dart';

enum AdminEventType {
  pinCreated,
  unlocked,
  unlockFailed,
  lockedOut,
  locked,
  pinChanged,
  settingsChanged,
  settingsReset,
  peerInjected,
  peerRemoved,
  historyCleared,
  adminReset,
}

/// One entry in the in-memory admin audit log. Never persisted: the log is
/// a diagnostic aid for the current run, and keeping it off disk means it
/// can never leak session details.
@immutable
class AdminEvent {
  const AdminEvent({required this.type, required this.at, this.detail = ''});

  final AdminEventType type;
  final DateTime at;
  final String detail;

  String get title {
    switch (type) {
      case AdminEventType.pinCreated:
        return 'Admin PIN created';
      case AdminEventType.unlocked:
        return 'Admin unlocked';
      case AdminEventType.unlockFailed:
        return 'Wrong PIN';
      case AdminEventType.lockedOut:
        return 'Locked out after repeated failures';
      case AdminEventType.locked:
        return 'Admin locked';
      case AdminEventType.pinChanged:
        return 'PIN changed';
      case AdminEventType.settingsChanged:
        return 'Settings changed';
      case AdminEventType.settingsReset:
        return 'Settings reset to defaults';
      case AdminEventType.peerInjected:
        return 'Synthetic peer injected';
      case AdminEventType.peerRemoved:
        return 'Synthetic peer removed';
      case AdminEventType.historyCleared:
        return 'Session history cleared';
      case AdminEventType.adminReset:
        return 'Admin PIN removed';
    }
  }
}
