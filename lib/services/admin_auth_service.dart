// PIN LOCK: one local PIN, used twice with separate storage:
// - the admin PIN guards the on-device admin panel (diagnostics, radio and
//   alert settings, synthetic test peers), and
// - the account PIN (`AdminAuthService.account`) guards the signed-in
//   account on this device: the Account screen, console and reports.
// Both are local-only and separate from the server password.
//
// The PIN is stretched with PBKDF2-HMAC-SHA256 and a random salt, and
// compared in constant time. Too many wrong attempts lock it for a while;
// the providers also lock it again after a period of inactivity.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:echo_pin/services/key_value_store.dart';
import 'package:flutter/foundation.dart';

enum AdminAuthStatus { success, wrongPin, lockedOut, noPin }

@immutable
class AdminAuthResult {
  const AdminAuthResult(
    this.status, {
    this.attemptsRemaining,
    this.lockedUntil,
    this.lockouts = 0,
  });

  final AdminAuthStatus status;
  final int? attemptsRemaining;
  final DateTime? lockedUntil;

  /// Lockouts in a row since the last correct PIN, this one included. The
  /// account lock signs out after a few (see `AccountLockProvider`).
  final int lockouts;

  bool get ok => status == AdminAuthStatus.success;
}

/// PBKDF2-HMAC-SHA256 (RFC 8018 §5.2), built only from the vetted HMAC in
/// `package:crypto`. Verified against the RFC 7914 §11 test vector in tests.
Uint8List pbkdf2Sha256({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  int keyLength = 32,
}) {
  if (iterations < 1) throw ArgumentError.value(iterations, 'iterations');
  final Hmac prf = Hmac(sha256, password);
  const int hLen = 32;
  final int blocks = (keyLength + hLen - 1) ~/ hLen;
  final BytesBuilder out = BytesBuilder(copy: false);
  for (int i = 1; i <= blocks; i++) {
    final Uint8List block = Uint8List.fromList(<int>[
      ...salt,
      (i >> 24) & 0xff,
      (i >> 16) & 0xff,
      (i >> 8) & 0xff,
      i & 0xff,
    ]);
    List<int> u = prf.convert(block).bytes;
    final Uint8List t = Uint8List.fromList(u);
    for (int c = 1; c < iterations; c++) {
      u = prf.convert(u).bytes;
      for (int j = 0; j < hLen; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, keyLength);
}

/// Local, offline admin authentication.
///
/// - The PIN is never stored. A salted PBKDF2 hash is written to the
///   [KeyValueStore] chosen by `Bootstrap` (OS keystore when available).
/// - After [maxAttempts] consecutive failures, verification is refused for
///   [lockoutDuration]. The counter and deadline are persisted so restarting
///   the app does not reset them.
class AdminAuthService {
  /// The admin panel's PIN.
  AdminAuthService({
    required KeyValueStore kv,
    this.iterations = 20000,
    this.maxAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 60),
    this.useIsolate = true,
    DateTime Function()? clock,
  }) : _kv = kv,
       _clock = clock ?? DateTime.now,
       _kPin = 'echo_pin.admin_pin_v1',
       _kLock = 'echo_pin.admin_lock_v1';

  /// The account PIN: same rules, its own storage, so the two PINs (and
  /// their lockouts) never affect each other.
  AdminAuthService.account({
    required KeyValueStore kv,
    this.iterations = 20000,
    this.maxAttempts = 5,
    this.lockoutDuration = const Duration(seconds: 60),
    this.useIsolate = true,
    DateTime Function()? clock,
  }) : _kv = kv,
       _clock = clock ?? DateTime.now,
       _kPin = 'echo_pin.account_pin_v1',
       _kLock = 'echo_pin.account_lock_v1';

  final String _kPin;
  final String _kLock;
  static const String _scheme = 'pbkdf2-sha256';
  static const String _sep = r'$';
  static const int minPinLength = 4;
  static const int maxPinLength = 12;

  final KeyValueStore _kv;
  final int iterations;
  final int maxAttempts;
  final Duration lockoutDuration;

  /// Derive keys on a background isolate. Disable in widget tests, where
  /// isolates never complete inside the fake-async zone.
  final bool useIsolate;
  final DateTime Function() _clock;

  /// Returns a human-readable problem with [pin], or null if acceptable.
  static String? validatePin(String pin) {
    if (pin.length < minPinLength || pin.length > maxPinLength) {
      return 'PIN must be $minPinLength–$maxPinLength digits';
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(pin)) return 'PIN must be digits only';
    return null;
  }

  Future<bool> hasPin() async => (await _kv.read(_kPin)) != null;

  Future<void> setPin(String pin) async {
    final String? problem = validatePin(pin);
    if (problem != null) throw ArgumentError(problem);
    final math.Random rng = math.Random.secure();
    final List<int> salt = List<int>.generate(16, (_) => rng.nextInt(256));
    final Uint8List hash = await _derive(pin, salt, iterations);
    await _kv.write(
      _kPin,
      <String>[_scheme, '$iterations', _hex(salt), _hex(hash)].join(_sep),
    );
    await _writeLock(0, null);
  }

  Future<DateTime?> lockedUntil() async {
    final (int _, DateTime? until, int _) = await _readLock();
    if (until == null || !until.isAfter(_clock())) return null;
    return until;
  }

  Future<AdminAuthResult> verify(String pin) async {
    final String? stored = await _kv.read(_kPin);
    if (stored == null) return const AdminAuthResult(AdminAuthStatus.noPin);

    final (int failures, DateTime? until, int lockouts) = await _readLock();
    final DateTime now = _clock();
    if (until != null && until.isAfter(now)) {
      return AdminAuthResult(
        AdminAuthStatus.lockedOut,
        lockedUntil: until,
        lockouts: lockouts,
      );
    }
    // A lockout that has expired starts a fresh window.
    final int priorFailures = until != null ? 0 : failures;

    if (await _matches(pin, stored)) {
      await _writeLock(0, null);
      return const AdminAuthResult(AdminAuthStatus.success);
    }

    final int nextFailures = priorFailures + 1;
    if (nextFailures >= maxAttempts) {
      final DateTime lockUntil = now.add(lockoutDuration);
      await _writeLock(0, lockUntil, lockouts + 1);
      return AdminAuthResult(
        AdminAuthStatus.lockedOut,
        lockedUntil: lockUntil,
        lockouts: lockouts + 1,
      );
    }
    await _writeLock(nextFailures, null, lockouts);
    return AdminAuthResult(
      AdminAuthStatus.wrongPin,
      attemptsRemaining: maxAttempts - nextFailures,
      lockouts: lockouts,
    );
  }

  /// Verifies [currentPin] (subject to lockout) then stores [newPin].
  Future<AdminAuthResult> changePin(String currentPin, String newPin) async {
    final String? problem = validatePin(newPin);
    if (problem != null) throw ArgumentError(problem);
    final AdminAuthResult result = await verify(currentPin);
    if (result.ok) await setPin(newPin);
    return result;
  }

  Future<void> clearPin() async {
    await _kv.delete(_kPin);
    await _kv.delete(_kLock);
  }

  Future<bool> _matches(String pin, String stored) async {
    final List<String> parts = stored.split(_sep);
    if (parts.length != 4 || parts[0] != _scheme) return false;
    final int? iters = int.tryParse(parts[1]);
    if (iters == null || iters < 1) return false;
    final List<int>? salt = _unhex(parts[2]);
    final List<int>? expected = _unhex(parts[3]);
    if (salt == null || expected == null) return false;
    final Uint8List actual = await _derive(pin, salt, iters);
    return _constantTimeEquals(actual, expected);
  }

  Future<Uint8List> _derive(String pin, List<int> salt, int iters) {
    final _DeriveArgs args = _DeriveArgs(utf8.encode(pin), salt, iters);
    // Off the UI isolate on native; compute() runs inline on web.
    if (!useIsolate) return Future<Uint8List>.value(_deriveEntry(args));
    return compute(_deriveEntry, args);
  }

  /// `failures|lockedUntilMs|lockouts`. Records written before lockouts
  /// were counted have two fields; the count then starts at 0.
  Future<(int, DateTime?, int)> _readLock() async {
    final String? raw = await _kv.read(_kLock);
    if (raw == null) return (0, null, 0);
    final List<String> parts = raw.split('|');
    final int failures = int.tryParse(parts[0]) ?? 0;
    final int? untilMs = parts.length > 1 ? int.tryParse(parts[1]) : null;
    final DateTime? until = untilMs == null || untilMs == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(untilMs);
    final int lockouts = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    return (failures, until, lockouts);
  }

  Future<void> _writeLock(int failures, DateTime? until, [int lockouts = 0]) {
    return _kv.write(
      _kLock,
      '$failures|${until?.millisecondsSinceEpoch ?? 0}|$lockouts',
    );
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int>? _unhex(String hex) {
    if (hex.isEmpty || hex.length.isOdd) return null;
    final List<int> out = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      final int? b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      out.add(b);
    }
    return out;
  }
}

class _DeriveArgs {
  const _DeriveArgs(this.password, this.salt, this.iterations);
  final List<int> password;
  final List<int> salt;
  final int iterations;
}

Uint8List _deriveEntry(_DeriveArgs a) =>
    pbkdf2Sha256(password: a.password, salt: a.salt, iterations: a.iterations);
