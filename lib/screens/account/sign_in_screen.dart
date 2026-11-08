import 'dart:async';

import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/providers/account_scope.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:echo_pin/widgets/ui_bits.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum _Mode { signIn, register, verify, forgot, reset }

/// Sign in, create an account, confirm the email code, or reset a
/// password, in one calm screen that changes shape instead of pushing
/// five routes.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  /// Returns true when the person ends up signed in.
  static Future<bool> open(BuildContext context) async {
    final bool? ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const SignInScreen()),
    );
    return ok ?? false;
  }

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _totp = TextEditingController();
  _Mode _mode = _Mode.signIn;
  bool _needTotp = false;
  bool _busy = false;
  bool _showPassword = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    final AccountProvider a = AccountScope.read(context);
    if (a.pendingEmail != null) {
      _email.text = a.pendingEmail!;
      _mode = _Mode.verify;
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _email, _password, _name, _code, _totp,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _go(_Mode m, {String? info}) => setState(() {
    _mode = m;
    _error = null;
    _info = info;
    _code.clear();
    if (m != _Mode.signIn) _needTotp = false;
  });

  Future<void> _submit() async {
    if (_busy) return;
    final AccountProvider a = AccountScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (_mode) {
        case _Mode.signIn:
          await a.signIn(
            email: _email.text,
            password: _password.text,
            totp: _needTotp ? _totp.text : null,
          );
          if (mounted) Navigator.of(context).pop(true);
          return;
        case _Mode.register:
          await a.signUp(email: _email.text, password: _password.text, displayName: _name.text);
          _go(_Mode.verify, info: 'We sent an 8-digit code to ${_email.text.trim()}.');
        case _Mode.verify:
          await a.verifyEmail(_code.text, password: _password.text);
          // Signing in right after verifying saves a step.
          await a.signIn(email: _email.text, password: _password.text);
          if (mounted) Navigator.of(context).pop(true);
          return;
        case _Mode.forgot:
          await a.forgotPassword(_email.text);
          _go(_Mode.reset, info: 'If ${_email.text.trim()} has an account, a reset code is on its way.');
        case _Mode.reset:
          await a.resetPassword(email: _email.text, code: _code.text, newPassword: _password.text);
          _go(_Mode.signIn, info: 'Password changed. Sign in with the new one.');
      }
    } on AccountError catch (e) {
      if (e.code == 'totp_required') {
        setState(() {
          _needTotp = true;
          _info = e.message;
        });
      } else if (e.code == 'email_unverified') {
        // Before: cancelVerification() cleared the pending email, so the
        // resend silently did nothing and Confirm then failed.
        await a.resumeVerification(_email.text);
        _go(_Mode.verify, info: e.message);
      } else if (e.code == 'password_mismatch') {
        // Someone re-registered this address with another password, or
        // the password was mistyped. Start the sign-up again.
        a.cancelVerification();
        _go(_Mode.register);
        setState(() => _error = e.message);
      } else if (_mode == _Mode.verify && e.code != 'invalid_code' && e.code != 'code_expired') {
        // Verified, but the automatic sign-in failed (e.g. password was
        // re-typed). Let them sign in by hand.
        _go(_Mode.signIn, info: 'Email confirmed. Sign in to continue.');
        setState(() => _error = e.message);
      } else {
        setState(() => _error = e.message);
      }
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    final AccountProvider a = AccountScope.read(context);
    try {
      await a.resendCode();
      setState(() => _info = 'A new code is on its way.');
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AccountProvider a = AccountScope.of(context);
    final ThemeData t = Theme.of(context);
    final (String title, String subtitle, String action) = switch (_mode) {
      _Mode.signIn => ('Sign in', 'Use your EchoPin account to start live sessions.', 'Sign in'),
      _Mode.register => ('Create account', 'One account on all your devices.', 'Create account'),
      _Mode.verify => ('Check your email', 'Enter the 8-digit code we sent.', 'Confirm'),
      _Mode.forgot => ('Reset password', 'We will email you a code.', 'Send code'),
      _Mode.reset => ('New password', 'Enter the code and choose a new password.', 'Change password'),
    };
    final bool showEmail = _mode != _Mode.verify;
    final bool showPassword = _mode == _Mode.signIn || _mode == _Mode.register ||
        _mode == _Mode.reset || (_mode == _Mode.verify && _password.text.isEmpty);
    final bool showCode = _mode == _Mode.verify || _mode == _Mode.reset;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: AutofillGroup(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: <Widget>[
                  Text(subtitle, style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 20),
                  if (a.signedOutReason != null && _mode == _Mode.signIn) ...<Widget>[
                    NoticeTray(icon: Icons.shield_outlined, text: a.signedOutReason!, color: EchoTheme.checkIn),
                    const SizedBox(height: 12),
                  ],
                  AnimatedSize(
                    duration: EchoTheme.fast,
                    child: _info == null
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: NoticeTray(icon: Icons.mark_email_read_outlined, text: _info!),
                          ),
                  ),
                  if (_mode == _Mode.register) ...<Widget>[
                    TextField(
                      key: const Key('signin.name'),
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      autofillHints: const <String>[AutofillHints.name],
                      decoration: const InputDecoration(labelText: 'Your name'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (showEmail) ...<Widget>[
                    TextField(
                      key: const Key('signin.email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const <String>[AutofillHints.email],
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Email'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (showCode) ...<Widget>[
                    TextField(
                      key: const Key('signin.code'),
                      controller: _code,
                      keyboardType: TextInputType.number,
                      autofillHints: const <String>[AutofillHints.oneTimeCode],
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(8),
                      ],
                      style: const TextStyle(letterSpacing: 6, fontSize: 20),
                      decoration: const InputDecoration(labelText: '8-digit code from the email'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (showPassword) ...<Widget>[
                    TextField(
                      key: const Key('signin.password'),
                      controller: _password,
                      obscureText: !_showPassword,
                      autofillHints: <String>[
                        _mode == _Mode.signIn ? AutofillHints.password : AutofillHints.newPassword,
                      ],
                      decoration: InputDecoration(
                        labelText: _mode == _Mode.reset ? 'New password' : 'Password',
                        helperText: _mode == _Mode.signIn ? null : 'At least 10 characters. A short phrase works well.',
                        suffixIcon: IconButton(
                          tooltip: _showPassword ? 'Hide password' : 'Show password',
                          icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                      ),
                      onSubmitted: (_) => unawaited(_submit()),
                    ),
                    const SizedBox(height: 12),
                  ],
                  AnimatedSize(
                    duration: EchoTheme.medium,
                    curve: EchoTheme.enter,
                    child: !(_needTotp && _mode == _Mode.signIn)
                        ? const SizedBox(width: double.infinity)
                        : TextField(
                            key: const Key('signin.totp'),
                            controller: _totp,
                            autofocus: true,
                            keyboardType: TextInputType.number,
                            inputFormatters: <TextInputFormatter>[
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6),
                            ],
                            style: const TextStyle(letterSpacing: 6, fontSize: 20),
                            decoration: const InputDecoration(
                              labelText: 'Authenticator code',
                              prefixIcon: Icon(Icons.verified_user_outlined),
                            ),
                            onSubmitted: (_) => unawaited(_submit()),
                          ),
                  ),
                  ErrorLine(_error),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('signin.submit'),
                    onPressed: _busy ? null : () => unawaited(_submit()),
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                        : Text(action),
                  ),
                  const SizedBox(height: 8),
                  ..._links(),
                  const SizedBox(height: 24),
                  Text(
                    'Your account keeps an emergency record of live sessions, '
                    'sealed so nobody can read it unless a responder opens it '
                    'for a stated reason, which is logged. Locations are never '
                    'recorded.',
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _links() {
    switch (_mode) {
      case _Mode.signIn:
        return <Widget>[
          TextButton(
            key: const Key('signin.toRegister'),
            onPressed: () => _go(_Mode.register),
            child: const Text('New here? Create an account'),
          ),
          TextButton(onPressed: () => _go(_Mode.forgot), child: const Text('Forgot password?')),
        ];
      case _Mode.register:
        return <Widget>[
          TextButton(onPressed: () => _go(_Mode.signIn), child: const Text('I already have an account')),
        ];
      case _Mode.verify:
        return <Widget>[
          TextButton(onPressed: () => unawaited(_resend()), child: const Text('Send a new code')),
          TextButton(
            onPressed: () {
              AccountScope.read(context).cancelVerification();
              _go(_Mode.register);
            },
            child: const Text('Wrong email? Start again'),
          ),
        ];
      case _Mode.forgot:
      case _Mode.reset:
        return <Widget>[
          TextButton(onPressed: () => _go(_Mode.signIn), child: const Text('Back to sign in')),
        ];
    }
  }
}
