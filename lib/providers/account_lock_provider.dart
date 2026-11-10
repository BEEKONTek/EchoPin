// ACCOUNT LOCK: a PIN in front of the signed-in account on this device.
//
// The server password proves who you are when you sign in. After that the
// phone stays signed in for weeks, so anyone holding it could open the
// Account screen, the console or your reports. This lock asks for a local
// PIN first, the same way the admin panel does.
//
// Rules:
// - Guards Account, the console and reports. Never sessions, check-ins or
//   SOS: help must not wait behind a PIN.
// - The PIN belongs to one sign-in. It is wiped on sign-out and on every
//   fresh sign-in, so a shared phone never inherits someone else's PIN, and
//   "forgot my PIN" is simply: sign out, sign in with your password.
// - 5 wrong PINs lock it for a minute; the 3rd lockout in a row signs the
//   account out (15 guesses in total), which makes guessing hopeless.
// - Locks again after [autoLockAfter] without a touch on a guarded screen,
//   measured on the wall clock so time spent in the background counts.

import 'dart:async';

import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:flutter/foundation.dart';

/// Thrown when an action needs the account unlocked.
class AccountLockedException implements Exception {
  const AccountLockedException();
  @override
  String toString() => 'Your account is locked on this device';
}

class AccountLockProvider extends ChangeNotifier {
  AccountLockProvider({
    required AdminAuthService auth,
    required AccountProvider account,
    this.autoLockAfter = const Duration(minutes: 5),
    this.maxLockouts = 3,
    DateTime Function()? clock,
  }) : _auth = auth,
       _account = account,
       _clock = clock ?? DateTime.now {
    _account.addListener(_onAccountChanged);
    _onAccountChanged();
  }

  final AdminAuthService _auth;
  final AccountProvider _account;
  final Duration autoLockAfter;

  /// Lockouts in a row that sign the account out.
  final int maxLockouts;
  final DateTime Function() _clock;

  static const String tooManyAttemptsReason =
      'Signed out after too many wrong PINs. Sign in with your password, '
      'then choose a new PIN.';

  bool _unlocked = false;
  bool? _hasPin;
  DateTime _lastActive = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _autoLock;
  bool _disposed = false;

  /// Sign-in state as last seen, once the account has loaded.
  bool? _wasSignedIn;

  bool get isUnlocked => _unlocked;

  /// Null until [refresh] has resolved it.
  bool? get hasPin => _hasPin;

  Future<void> refresh() async {
    _hasPin = await _auth.hasPin();
    _notify();
  }

  Future<DateTime?> lockedUntil() => _auth.lockedUntil();

  // ── PIN ────────────────────────────────────────────────────────────────

  /// First PIN for this sign-in. Refuses if one exists, so it can't be used
  /// to replace the owner's PIN without knowing it.
  Future<void> createPin(String pin) async {
    _requireSignedIn();
    if (await _auth.hasPin()) throw StateError('An account PIN already exists');
    await _auth.setPin(pin);
    _hasPin = true;
    _setUnlocked(true);
  }

  Future<AdminAuthResult> unlock(String pin) async {
    _requireSignedIn();
    final AdminAuthResult r = await _auth.verify(pin);
    switch (r.status) {
      case AdminAuthStatus.success:
        _setUnlocked(true);
      case AdminAuthStatus.lockedOut:
        if (r.lockouts >= maxLockouts) {
          // Someone is guessing. The password is the real secret, so end
          // this sign-in; the owner signs in again. _onAccountChanged wipes
          // the PIN when the sign-out lands.
          await _account.signOut(reason: tooManyAttemptsReason);
        }
        _notify();
      case AdminAuthStatus.wrongPin:
        _notify();
      case AdminAuthStatus.noPin:
        _hasPin = false;
        _notify();
    }
    return r;
  }

  /// Needs the current PIN (with the usual lockout), then stores [newPin].
  Future<AdminAuthResult> changePin(String currentPin, String newPin) async {
    if (!_unlocked) throw const AccountLockedException();
    final AdminAuthResult r = await _auth.changePin(currentPin, newPin);
    if (r.status == AdminAuthStatus.lockedOut) _setUnlocked(false);
    touch();
    return r;
  }

  /// "Forgot your PIN?": sign out; sign-in with the password sets a new one.
  Future<void> forgotPin() => _account.signOut();

  // ── Locking ────────────────────────────────────────────────────────────

  void lock() {
    if (_unlocked) _setUnlocked(false);
  }

  /// Any touch on a guarded screen postpones the auto-lock.
  void touch() {
    if (!_unlocked) return;
    _lastActive = _clock();
    _armTimer();
  }

  /// Call when the app returns to the foreground: timers don't run while a
  /// phone has the app suspended, so compare wall-clock time instead.
  void checkIdle() {
    if (_unlocked && _clock().difference(_lastActive) >= autoLockAfter) {
      _setUnlocked(false);
    }
  }

  void _setUnlocked(bool value) {
    _unlocked = value;
    if (value) {
      _lastActive = _clock();
      _armTimer();
    } else {
      _autoLock?.cancel();
      _autoLock = null;
    }
    _notify();
  }

  void _armTimer() {
    _autoLock?.cancel();
    // Re-armed on every touch, so when it fires the idle time has passed.
    // (Not checkIdle: the wall clock can read a hair short of the timer.)
    _autoLock = Timer(autoLockAfter, lock);
  }

  // ── Sign-in changes ────────────────────────────────────────────────────

  /// The PIN belongs to one sign-in: forget it whenever that changes. The
  /// first snapshot after loading is the app restoring a saved sign-in,
  /// not a change, so the PIN survives restarts.
  void _onAccountChanged() {
    if (!_account.loaded) return;
    final bool signedIn = _account.signedIn;
    final bool? before = _wasSignedIn;
    _wasSignedIn = signedIn;
    if (before == null) {
      unawaited(refresh());
      return;
    }
    if (before != signedIn) unawaited(_forgetPin());
  }

  Future<void> _forgetPin() async {
    _hasPin = false;
    _setUnlocked(false);
    await _auth.clearPin();
  }

  void _requireSignedIn() {
    if (!_account.signedIn) throw StateError('Not signed in');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _autoLock?.cancel();
    _account.removeListener(_onAccountChanged);
    super.dispose();
  }
}
