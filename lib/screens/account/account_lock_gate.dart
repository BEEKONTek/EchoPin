// ACCOUNT LOCK GATE: the PIN screen in front of Account, the console and
// reports. Rules live in AccountLockProvider; this file is only the UI.

import 'dart:async';

import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/providers/account_lock_provider.dart';
import 'package:echo_pin/providers/account_lock_scope.dart';
import 'package:echo_pin/providers/account_scope.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:echo_pin/widgets/pin_field.dart';
import 'package:flutter/material.dart';

/// Pushes [child] behind the account lock.
Future<T?> pushLocked<T>(BuildContext context, Widget child) =>
    Navigator.of(context).push<T>(
      MaterialPageRoute<T>(builder: (_) => AccountLockGuard(child: child)),
    );

/// Shows [child] only while the account is unlocked, and the PIN panel
/// (first PIN for this sign-in, or unlock) in its place otherwise.
///
/// The child is built at the first unlock and then kept alive, only hidden,
/// if the lock closes again: an auto-lock doesn't lose a half-written
/// report or your place in the console, and the screen's data isn't loaded
/// before the PIN has been entered. Signing out closes the screen.
class AccountLockGuard extends StatefulWidget {
  const AccountLockGuard({super.key, required this.child});

  final Widget child;

  @override
  State<AccountLockGuard> createState() => _AccountLockGuardState();
}

class _AccountLockGuardState extends State<AccountLockGuard> {
  bool _everUnlocked = false;
  bool _leaving = false;

  /// Closes this screen's own route, wherever it is in the stack (a console
  /// opened from Account closes too when the account signs out).
  void _leave() {
    if (_leaving) return;
    _leaving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ModalRoute<Object?>? route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final NavigatorState nav = Navigator.of(context);
      route.isCurrent ? nav.pop() : nav.removeRoute(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AccountLockProvider lock = AccountLockScope.of(context);
    final AccountProvider account = AccountScope.of(context);
    if (!account.signedIn) {
      _leave();
      return const Scaffold();
    }
    final bool open = lock.isUnlocked;
    if (open) _everUnlocked = true;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (_everUnlocked)
          Offstage(
            offstage: !open,
            child: TickerMode(
              enabled: open,
              child: Listener(
                // Any touch postpones the auto-lock.
                onPointerDown: (_) => lock.touch(),
                child: widget.child,
              ),
            ),
          ),
        // Its own messenger: a snack bar meant for the hidden screen (e.g.
        // "PIN changed" just before locking) must not appear on the PIN
        // panel too. Two copies of one snack bar in a route also crash.
        if (!open) const ScaffoldMessenger(child: AccountPinPanel()),
      ],
    );
  }
}

/// Create the account PIN (first time after signing in) or enter it.
class AccountPinPanel extends StatefulWidget {
  const AccountPinPanel({super.key});

  @override
  State<AccountPinPanel> createState() => _AccountPinPanelState();
}

class _AccountPinPanelState extends State<AccountPinPanel> {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  int _lockouts = 0;
  DateTime? _lockedUntil;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final AccountLockProvider lock = AccountLockScope.read(context);
    unawaited(() async {
      if (lock.hasPin == null) await lock.refresh();
      _setLockout(await lock.lockedUntil());
    }());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _setLockout(DateTime? until) {
    if (!mounted) return;
    _ticker?.cancel();
    setState(() => _lockedUntil = until);
    if (until == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) return t.cancel();
      if (!DateTime.now().isBefore(until)) {
        t.cancel();
        setState(() {
          _lockedUntil = null;
          _error = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final AccountLockProvider lock = AccountLockScope.read(context);
    final bool setup = lock.hasPin == false;
    final String pin = _pin.text;
    final String? problem = AdminAuthService.validatePin(pin);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (setup && pin != _confirm.text) {
      setState(() => _error = 'PINs do not match');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (setup) {
        await lock.createPin(pin);
        return; // the guard now shows the screen
      }
      final AdminAuthResult r = await lock.unlock(pin);
      if (!mounted) return;
      _pin.clear();
      switch (r.status) {
        case AdminAuthStatus.success:
          break;
        case AdminAuthStatus.wrongPin:
          setState(() {
            _lockouts = r.lockouts;
            _error = 'Wrong PIN. ${r.attemptsRemaining} attempt(s) left.';
          });
        case AdminAuthStatus.lockedOut:
          setState(() => _lockouts = r.lockouts);
          _setLockout(r.lockedUntil);
        case AdminAuthStatus.noPin:
          setState(() => _error = null); // panel switches to "create"
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Forgot your PIN?'),
        content: const Text(
          'Sign out, then sign in again with your email and password '
          '(and two-step code, if it is on). You will choose a new PIN. '
          'Reports waiting to send stay on this phone.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('accountLock.forgotConfirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AccountLockScope.read(context).forgotPin();
  }

  @override
  Widget build(BuildContext context) {
    final AccountLockProvider lock = AccountLockScope.of(context);
    final bool? hasPin = lock.hasPin;
    final bool setup = hasPin == false;
    final ThemeData theme = Theme.of(context);
    final int? lockSeconds = _lockedUntil == null
        ? null
        : _lockedUntil!.difference(DateTime.now()).inSeconds + 1;
    final bool locked = lockSeconds != null && lockSeconds > 0;
    final int lockoutsLeft = lock.maxLockouts - _lockouts;

    return Scaffold(
      appBar: AppBar(title: Text(setup ? 'Protect your account' : 'Account locked')),
      body: hasPin == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(24),
                  children: <Widget>[
                    Icon(
                      setup ? Icons.shield_outlined : Icons.lock_outline,
                      size: 56,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      setup
                          ? 'Choose a PIN (${AdminAuthService.minPinLength}–'
                                '${AdminAuthService.maxPinLength} digits) for your account on '
                                'this phone. You will enter it to open your account, reports '
                                'and the console. Sessions and SOS never ask for it.'
                          : 'Enter your account PIN.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    PinField(
                      key: const Key('accountLock.pin'),
                      controller: _pin,
                      label: setup ? 'New PIN' : 'PIN',
                      enabled: !_busy && !locked,
                      autofocus: true,
                      onSubmitted: setup ? null : _submit,
                    ),
                    if (setup) ...<Widget>[
                      const SizedBox(height: 12),
                      PinField(
                        key: const Key('accountLock.confirm'),
                        controller: _confirm,
                        label: 'Confirm PIN',
                        enabled: !_busy,
                        onSubmitted: _submit,
                      ),
                    ],
                    if (_error != null || locked) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        locked ? 'Too many attempts. Try again in $lockSeconds s.' : _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    // Say so before it happens, not after.
                    if (!setup && _lockouts > 0 && lockoutsLeft > 0) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        lockoutsLeft == 1
                            ? 'One more lockout signs this account out of this phone.'
                            : '$lockoutsLeft more lockouts sign this account out of this phone.',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('accountLock.submit'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                      onPressed: _busy || locked ? null : _submit,
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(setup ? 'Create PIN' : 'Unlock'),
                    ),
                    if (!setup) ...<Widget>[
                      const SizedBox(height: 12),
                      TextButton(
                        key: const Key('accountLock.forgot'),
                        onPressed: _busy ? null : _forgot,
                        child: const Text('Forgot your PIN?'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
