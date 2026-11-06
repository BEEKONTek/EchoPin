import 'package:flutter/foundation.dart';

/// Every failure the app can surface to a person, as a closed set.
///
/// Services throw or emit these instead of raw exceptions so the UI can pick
/// the right treatment (inline field error, tray with an action, snackbar)
/// and always show a human sentence instead of a stack trace.
@immutable
sealed class EchoError implements Exception {
  const EchoError();

  /// Short, human-readable sentence for the UI.
  String get message;

  @override
  String toString() => message;
}

// ── Input ──────────────────────────────────────────────────────────────────

enum CodeProblem {
  empty,
  wrongLength,
  invalidCharacters,
  checksumMismatch,
  notEchoPin,
  unsupportedVersion,
}

/// A session code, join link or QR payload that cannot be used.
final class InvalidCodeError extends EchoError {
  const InvalidCodeError(this.problem, {this.detail = ''});

  final CodeProblem problem;
  final String detail;

  @override
  String get message {
    switch (problem) {
      case CodeProblem.empty:
        return 'Enter a session code';
      case CodeProblem.wrongLength:
        return 'Codes have 16 characters after ECHO, plus a 2-character check'
            '${detail.isEmpty ? '' : ' (got $detail)'}';
      case CodeProblem.invalidCharacters:
        return 'Codes never contain $detail. Check for 0/O, 1/I/L or U';
      case CodeProblem.checksumMismatch:
        return 'That code does not check out. Look for a typo';
      case CodeProblem.notEchoPin:
        return 'That is not an EchoPin code';
      case CodeProblem.unsupportedVersion:
        return 'That code is from a newer EchoPin. Update the app to join';
    }
  }
}

/// A free-text field (display name, session name, ping note) that fails
/// validation.
final class InvalidInputError extends EchoError {
  const InvalidInputError(this.field, this.reason);

  final String field;
  final String reason;

  @override
  String get message => '$field $reason';
}

// ── Radios and permissions ─────────────────────────────────────────────────

enum RadioKind { bluetooth, wifi }

enum RadioProblem { off, unauthorized, unsupported }

final class RadioUnavailableError extends EchoError {
  const RadioUnavailableError(this.radio, this.problem);

  final RadioKind radio;
  final RadioProblem problem;

  @override
  String get message {
    final String name = radio == RadioKind.bluetooth ? 'Bluetooth' : 'Wi-Fi';
    switch (problem) {
      case RadioProblem.off:
        return radio == RadioKind.bluetooth
            ? 'Bluetooth is off. Turn it on to find people nearby'
            : 'Not on Wi-Fi. Join the same Wi-Fi or hotspot as your group';
      case RadioProblem.unauthorized:
        return 'EchoPin is not allowed to use $name';
      case RadioProblem.unsupported:
        return 'This device has no $name support';
    }
  }
}

enum PermissionKind { bluetooth, camera, notifications, localNetwork }

final class PermissionDeniedError extends EchoError {
  const PermissionDeniedError(this.kind, {this.permanently = false});

  final PermissionKind kind;

  /// True when the OS will no longer prompt; only Settings can fix it.
  final bool permanently;

  @override
  String get message {
    final String what = switch (kind) {
      PermissionKind.bluetooth => 'Bluetooth access',
      PermissionKind.camera => 'Camera access',
      PermissionKind.notifications => 'Notifications',
      PermissionKind.localNetwork => 'Local network access',
    };
    return permanently
        ? '$what is blocked. Enable it in Settings'
        : '$what was denied';
  }
}

// ── Session and transport ──────────────────────────────────────────────────

final class SessionFullError extends EchoError {
  const SessionFullError(this.limit);
  final int limit;

  @override
  String get message => 'Sessions are limited to $limit people';
}

final class NoRecipientsError extends EchoError {
  const NoRecipientsError();

  @override
  String get message => 'Nobody else is in the session yet';
}

final class NoTransportError extends EchoError {
  const NoTransportError();

  @override
  String get message =>
      'No way to reach anyone: turn on Bluetooth or join a Wi-Fi network';
}

final class TransportError extends EchoError {
  const TransportError(this.transport, this.reason);
  final String transport;
  final String reason;

  @override
  String get message => '$transport: $reason';
}

final class RateLimitedError extends EchoError {
  const RateLimitedError(this.retryAfter);
  final Duration retryAfter;

  @override
  String get message =>
      'Slow down. Try again in ${retryAfter.inSeconds.clamp(1, 999)} s';
}

// ── Security ───────────────────────────────────────────────────────────────

enum SecurityProblem {
  /// Ciphertext failed authentication: wrong session key or tampering.
  undecryptable,

  /// Inner Ed25519 signature did not verify.
  badSignature,

  /// Sender id does not match the key that signed the message.
  idMismatch,

  /// A peer id already bound to one key presented a different key.
  impersonation,

  /// Counter already seen or older than the replay window.
  replay,

  /// Timestamp outside the accepted clock-skew window.
  stale,

  /// Structurally invalid frame.
  malformed,

  /// Sender exceeded its message budget.
  flooding,
}

/// A message that was rejected. Surfaced in the admin log, and as a tray
/// for problems that suggest an active attacker (impersonation).
final class SecurityError extends EchoError {
  const SecurityError(this.problem, {this.peerId, this.detail = ''});

  final SecurityProblem problem;
  final String? peerId;
  final String detail;

  /// Problems worth interrupting the person for. The rest are expected
  /// background noise (duplicates over two radios, strangers' traffic).
  bool get alarming =>
      problem == SecurityProblem.impersonation ||
      problem == SecurityProblem.badSignature ||
      problem == SecurityProblem.idMismatch;

  @override
  String get message {
    switch (problem) {
      case SecurityProblem.undecryptable:
        return 'Ignored a message that was not encrypted for this session';
      case SecurityProblem.badSignature:
        return 'Rejected a message with a forged signature';
      case SecurityProblem.idMismatch:
        return 'Rejected a message whose sender id did not match its key';
      case SecurityProblem.impersonation:
        return 'Someone tried to impersonate a member of this session';
      case SecurityProblem.replay:
        return 'Dropped a replayed message';
      case SecurityProblem.stale:
        return 'Dropped a message with a bad timestamp';
      case SecurityProblem.malformed:
        return 'Dropped a malformed message';
      case SecurityProblem.flooding:
        return 'Throttled a peer sending too many messages';
    }
  }
}

/// Wraps anything unexpected so it still reaches the UI as a sentence.
final class UnexpectedError extends EchoError {
  const UnexpectedError(this.cause, [this.context = '']);
  final Object cause;
  final String context;

  @override
  String get message =>
      context.isEmpty ? 'Something went wrong: $cause' : '$context: $cause';
}

/// Normalises any thrown object into an [EchoError].
EchoError asEchoError(Object error, [String context = '']) {
  if (error is EchoError) return error;
  return UnexpectedError(error, context);
}
