import 'dart:async';

import 'package:echo_pin/providers/admin_provider.dart';
import 'package:echo_pin/providers/admin_scope.dart';
import 'package:echo_pin/screens/admin/admin_screen.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens the admin panel, going through the PIN gate unless already
/// unlocked.
Future<void> openAdmin(BuildContext context) {
  final AdminProvider admin = AdminScope.read(context);
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          admin.isUnlocked ? const AdminScreen() : const AdminGateScreen(),
    ),
  );
}

/// First-run PIN setup or PIN unlock, depending on whether a PIN exists.
class AdminGateScreen extends StatefulWidget {
  const AdminGateScreen({super.key});

  @override
  State<AdminGateScreen> createState() => _AdminGateScreenState();
}

class _AdminGateScreenState extends State<AdminGateScreen> {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  DateTime? _lockedUntil;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final AdminProvider admin = AdminScope.read(context);
    unawaited(() async {
      await admin.refresh();
      _setLockout(await admin.lockedUntil());
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

  Future<void> _submit(AdminProvider admin) async {
    if (_busy) return;
    final bool setup = admin.hasPin == false;
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
        await admin.createPin(pin);
      } else {
        final AdminAuthResult r = await admin.unlock(pin);
        switch (r.status) {
          case AdminAuthStatus.success:
            break;
          case AdminAuthStatus.wrongPin:
            _pin.clear();
            setState(
              () =>
                  _error = 'Wrong PIN. ${r.attemptsRemaining} attempt(s) left.',
            );
            return;
          case AdminAuthStatus.lockedOut:
            _pin.clear();
            _setLockout(r.lockedUntil);
            return;
          case AdminAuthStatus.noPin:
            setState(() => _error = 'No PIN set — create one.');
            return;
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const AdminScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AdminProvider admin = AdminScope.of(context);
    final bool? hasPin = admin.hasPin;
    final ThemeData theme = Theme.of(context);
    final int? lockSeconds = _lockedUntil == null
        ? null
        : _lockedUntil!.difference(DateTime.now()).inSeconds + 1;
    final bool locked = lockSeconds != null && lockSeconds > 0;
    final bool setup = hasPin == false;

    return Scaffold(
      appBar: AppBar(title: Text(setup ? 'Set up admin' : 'Admin login')),
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
                          ? 'Create an admin PIN '
                                '(${AdminAuthService.minPinLength}–'
                                '${AdminAuthService.maxPinLength} digits). '
                                'It protects diagnostics, test tools and '
                                'settings on this device.'
                          : 'Enter the admin PIN.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    _PinField(
                      key: const Key('admin.pin'),
                      controller: _pin,
                      label: setup ? 'New PIN' : 'PIN',
                      enabled: !_busy && !locked,
                      onSubmitted: setup ? null : () => _submit(admin),
                    ),
                    if (setup) ...<Widget>[
                      const SizedBox(height: 12),
                      _PinField(
                        key: const Key('admin.confirm'),
                        controller: _confirm,
                        label: 'Confirm PIN',
                        enabled: !_busy,
                        onSubmitted: () => _submit(admin),
                      ),
                    ],
                    if (_error != null || locked) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        locked
                            ? 'Too many attempts. Try again in '
                                  '$lockSeconds s.'
                            : _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      key: const Key('admin.submit'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _busy || locked ? null : () => _submit(admin),
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(setup ? 'Create PIN' : 'Unlock'),
                    ),
                    if (!setup) ...<Widget>[
                      const SizedBox(height: 16),
                      Text(
                        'Forgot the PIN? There is no remote reset: clear '
                        "EchoPin's app data in system settings.",
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

class _PinField extends StatelessWidget {
  const _PinField({
    super.key,
    required this.controller,
    required this.label,
    required this.enabled,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      obscureText: true,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(AdminAuthService.maxPinLength),
      ],
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
