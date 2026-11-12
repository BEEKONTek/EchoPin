import 'dart:async';

import 'package:echo_pin/account/account_models.dart';
import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/account/outbox.dart';
import 'package:echo_pin/providers/account_lock_scope.dart';
import 'package:echo_pin/providers/account_scope.dart';
import 'package:echo_pin/providers/outbox_scope.dart';
import 'package:echo_pin/screens/account/account_lock_gate.dart';
import 'package:echo_pin/screens/account/sign_in_screen.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:echo_pin/screens/console/console_screen.dart';
import 'package:echo_pin/screens/report_screen.dart';
import 'package:echo_pin/ui/format.dart';
import 'package:echo_pin/widgets/pin_field.dart';
import 'package:echo_pin/widgets/ui_bits.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Opens the account screen: sign-in first when signed out, then the
/// account PIN (created right after signing in, asked for after that).
Future<void> openAccount(BuildContext context) async {
  final AccountProvider a = AccountScope.read(context);
  if (!a.signedIn) {
    final bool ok = await SignInScreen.open(context);
    if (!ok || !context.mounted) return;
  }
  await pushLocked<void>(context, const AccountScreen());
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  Future<List<Map<String, dynamic>>>? _devices;
  Future<List<Map<String, dynamic>>>? _reports;

  @override
  void initState() {
    super.initState();
    _reload();
    unawaited(AccountScope.read(context).refreshMe().catchError((Object _) {}));
  }

  void _reload() {
    final AccountProvider a = AccountScope.read(context);
    setState(() {
      _devices = a.devices();
      _reports = a.myReports();
    });
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final AccountProvider a = AccountScope.of(context);
    final Outbox outbox = OutboxScope.of(context);
    final Account? me = a.account;
    final ThemeData t = Theme.of(context);
    if (me == null) {
      // Signed out from elsewhere (e.g. revoked); leave quietly.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold();
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account'),
        actions: <Widget>[
          IconButton(
            key: const Key('account.lock'),
            tooltip: 'Lock',
            icon: const Icon(Icons.lock),
            onPressed: () {
              AccountLockScope.read(context).lock();
              Navigator.of(context).maybePop();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: RefreshIndicator(
              onRefresh: () async => _reload(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: <Widget>[
                  Tray(
                    child: Row(
                      children: <Widget>[
                        CircleAvatar(
                          radius: 26,
                          child: Text(Fmt.initials(me.displayName)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                me.displayName,
                                style: t.textTheme.titleMedium,
                              ),
                              Text(me.email, style: t.textTheme.bodySmall),
                            ],
                          ),
                        ),
                        Pill(
                          me.role.wire,
                          color: me.canUseConsole
                              ? t.colorScheme.primary
                              : null,
                        ),
                      ],
                    ),
                  ),
                  if (me.canUseConsole) ...<Widget>[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('account.console'),
                      onPressed: () => unawaited(ConsoleScreen.open(context)),
                      icon: const Icon(Icons.dashboard_outlined),
                      label: const Text('Open central console'),
                    ),
                  ],
                  const SectionLabel('Security'),
                  // No OS keystore on this device: the sign-in key sits in
                  // ordinary app storage. Sessions here last 7 days, not 30.
                  if (!AccountScope.of(context).secureKeyStorage)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: NoticeTray(
                        icon: Icons.warning_amber_outlined,
                        text:
                            'This device has no secure key storage, so your sign-in key is '
                            'kept in ordinary app storage. You will be asked to sign in again '
                            'every 7 days. Avoid shared computers.',
                      ),
                    ),
                  Tray(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        ListTile(
                          leading: Icon(
                            me.totpEnabled
                                ? Icons.verified_user
                                : Icons.shield_outlined,
                          ),
                          title: const Text('Two-step sign-in'),
                          subtitle: Text(
                            me.totpEnabled
                                ? 'On. Sign-in asks for a code from your authenticator app'
                                : 'Off. Add a code from an authenticator app to sign-in',
                          ),
                          trailing: Text(
                            me.totpEnabled ? 'Turn off' : 'Set up',
                          ),
                          onTap: () => unawaited(
                            me.totpEnabled ? _disableTotp() : _setupTotp(),
                          ),
                        ),
                        const Divider(),
                        ListTile(
                          leading: const Icon(Icons.password),
                          title: const Text('Change password'),
                          subtitle: const Text('Signs out your other devices'),
                          onTap: () => unawaited(_changePassword()),
                        ),
                        const Divider(),
                        ListTile(
                          key: const Key('account.changePin'),
                          leading: const Icon(Icons.pin_outlined),
                          title: const Text('Account PIN'),
                          subtitle: const Text(
                            'Asked on this phone when you open your account. '
                            'Locks again after 5 minutes without use',
                          ),
                          trailing: const Text('Change'),
                          onTap: () => unawaited(_changePin()),
                        ),
                      ],
                    ),
                  ),
                  const SectionLabel('Devices'),
                  _Loader<List<Map<String, dynamic>>>(
                    future: _devices,
                    onRetry: _reload,
                    builder: (List<Map<String, dynamic>> devices) => Tray(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: <Widget>[
                          for (final Map<String, dynamic> d in devices.where(
                            (Map<String, dynamic> d) => d['revokedAt'] == null,
                          ))
                            ListTile(
                              leading: Icon(
                                d['current'] == true
                                    ? Icons.smartphone
                                    : Icons.devices_other,
                              ),
                              title: Text(
                                '${d['label']}${d['current'] == true ? ' (this one)' : ''}',
                              ),
                              subtitle: Text(
                                'EchoPin ${d['appVersion'] ?? '?'} · seen ${_ago(d['lastSeenAt'])}',
                              ),
                              trailing: d['current'] == true
                                  ? null
                                  : IconButton(
                                      tooltip: 'Remove this device',
                                      icon: const Icon(Icons.logout),
                                      onPressed: () => unawaited(_revoke(d)),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SectionLabel(
                    'My reports',
                    trailing: TextButton.icon(
                      key: const Key('account.report'),
                      onPressed: () async {
                        await ReportScreen.open(context);
                        if (mounted) _reload();
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Report a problem'),
                    ),
                  ),
                  _Loader<List<Map<String, dynamic>>>(
                    future: _reports,
                    onRetry: _reload,
                    builder: (List<Map<String, dynamic>> reports) =>
                        reports.isEmpty
                        ? const Tray(child: Text('No reports yet.'))
                        : Tray(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: <Widget>[
                                for (final Map<String, dynamic> r in reports)
                                  ListTile(
                                    title: Text(r['subject'] as String),
                                    subtitle: Text(
                                      r['resolution'] as String? ??
                                          'Sent ${_ago(r['createdAt'])}',
                                    ),
                                    trailing: Pill(
                                      r['status'] as String,
                                      color: statusColor(
                                        context,
                                        r['status'] as String,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                  const SectionLabel('Uploads'),
                  Tray(
                    child: Row(
                      children: <Widget>[
                        Icon(
                          outbox.pendingCount == 0
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_upload_outlined,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            outbox.pendingCount == 0
                                ? 'Everything is sent${outbox.lastSentAt == null ? '' : ' (last ${Fmt.ago(outbox.lastSentAt!.toLocal())})'}.'
                                : '${outbox.pendingCount} waiting to send. They go automatically when you are online.',
                          ),
                        ),
                        if (outbox.pendingCount > 0)
                          TextButton(
                            onPressed: outbox.isFlushing
                                ? null
                                : () async {
                                    final bool done = await outbox.flush();
                                    if (mounted && !done) {
                                      _snack('Still offline. Will keep trying');
                                    }
                                  },
                            child: const Text('Send now'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  OutlinedButton.icon(
                    key: const Key('account.signOut'),
                    onPressed: () async {
                      final NavigatorState nav = Navigator.of(context);
                      await a.signOut();
                      nav.pop();
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _ago(Object? iso) {
    final DateTime? t = iso is String ? DateTime.tryParse(iso) : null;
    return t == null ? '—' : Fmt.ago(t.toLocal());
  }

  // ── Actions ────────────────────────────────────────────────────────────

  Future<void> _changePin() async {
    final bool? done = await showDialog<bool>(
      context: context,
      builder: (_) => const _ChangePinDialog(),
    );
    if (done == true && mounted) _snack('Account PIN changed');
  }

  Future<void> _revoke(Map<String, dynamic> d) async {
    final bool ok = await _confirm(
      'Remove ${d['label']}?',
      'It is signed out at once and must sign in again to come back.',
      'Remove',
    );
    if (!ok || !mounted) return;
    try {
      await AccountScope.read(context).revokeDevice(d['id'] as String);
      _reload();
    } catch (e) {
      _snack(errorText(e));
    }
  }

  Future<void> _setupTotp() async {
    final AccountProvider a = AccountScope.read(context);
    final Map<String, dynamic> setup;
    try {
      setup = await a.totpSetup();
    } catch (e) {
      _snack(errorText(e));
      return;
    }
    if (!mounted) return;
    final bool? done = await showDialog<bool>(
      context: context,
      builder: (_) => _TotpDialog(
        uri: setup['otpauthUri'] as String,
        secret: setup['secret'] as String,
        onCode: (String code, String password) =>
            a.totpEnable(code, password: password),
      ),
    );
    if (done == true) _snack('Two-step sign-in is on');
  }

  Future<void> _disableTotp() async {
    final AccountProvider a = AccountScope.read(context);
    final List<String>? values = await _askFields(
      'Turn off two-step sign-in',
      <String>['Password', 'Authenticator code'],
      obscure: <bool>[true, false],
    );
    if (values == null) return;
    try {
      await a.totpDisable(password: values[0], code: values[1]);
      _snack('Two-step sign-in is off');
    } catch (e) {
      _snack(errorText(e));
    }
  }

  Future<void> _changePassword() async {
    final AccountProvider a = AccountScope.read(context);
    final List<String>? values = await _askFields(
      'Change password',
      <String>['Current password', 'New password'],
      obscure: <bool>[true, true],
    );
    if (values == null) return;
    try {
      await a.changePassword(values[0], values[1]);
      _snack('Password changed. Other devices were signed out');
      _reload();
    } catch (e) {
      _snack(errorText(e));
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<List<String>?> _askFields(
    String title,
    List<String> labels, {
    required List<bool> obscure,
  }) {
    final List<TextEditingController> controllers = labels
        .map((_) => TextEditingController())
        .toList();
    return showDialog<List<String>>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: controllers[i],
                  obscureText: obscure[i],
                  autofocus: i == 0,
                  maxLength: ProtocolLimits.maxPasswordLength,
                  decoration: InputDecoration(
                    labelText: labels[i],
                    counterText: '',
                  ),
                ),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              c,
              controllers.map((TextEditingController x) => x.text).toList(),
            ),
            child: const Text('Continue'),
          ),
        ],
      ),
    ).whenComplete(() {
      for (final TextEditingController x in controllers) {
        x.dispose();
      }
    });
  }
}

class _TotpDialog extends StatefulWidget {
  const _TotpDialog({
    required this.uri,
    required this.secret,
    required this.onCode,
  });
  final String uri;
  final String secret;

  /// Called with the authenticator code and the account password. The
  /// server asks for the password so a stolen session alone can't attach
  /// someone else's authenticator to this account.
  final Future<void> Function(String code, String password) onCode;

  @override
  State<_TotpDialog> createState() => _TotpDialogState();
}

class _TotpDialogState extends State<_TotpDialog> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCode(_code.text, _password.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set up two-step sign-in'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'Scan this with an authenticator app (Google Authenticator, '
              '1Password, Aegis…), then enter the 6-digit code it shows.',
            ),
            const SizedBox(height: 16),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              // A fixed box: AlertDialog measures its content's natural
              // size, and QrImageView (built on LayoutBuilder) can't answer
              // that, so without it the dialog throws a layout error.
              child: SizedBox.square(
                dimension: 200,
                child: QrImageView(data: widget.uri, size: 200),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              widget.secret,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            TextButton.icon(
              onPressed: () => unawaited(
                Clipboard.setData(ClipboardData(text: widget.secret)),
              ),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy key'),
            ),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(labelText: '6-digit code'),
            ),
            TextField(
              key: const ValueKey<String>('totp.password'),
              controller: _password,
              obscureText: true,
              maxLength: ProtocolLimits.maxPasswordLength,
              decoration: const InputDecoration(
                labelText: 'Your password',
                counterText: '',
              ),
              onSubmitted: (_) => unawaited(_submit()),
            ),
            ErrorLine(_error),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: const Text('Turn on'),
        ),
      ],
    );
  }
}

/// FutureBuilder with a loading state and a retry on failure.
class _Loader<T> extends StatelessWidget {
  const _Loader({
    required this.future,
    required this.builder,
    required this.onRetry,
  });
  final Future<T>? future;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (BuildContext context, AsyncSnapshot<T> snap) {
        if (snap.hasError) {
          return Tray(
            child: Row(
              children: <Widget>[
                Expanded(child: Text(errorText(snap.error!))),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          );
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return builder(snap.data as T);
      },
    );
  }
}

/// Current PIN, new PIN, confirm. A widget of its own so the text
/// controllers are disposed only once the dialog has finished closing.
class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog();

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _again = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String? problem = AdminAuthService.validatePin(_next.text);
    if (problem != null || _next.text != _again.text) {
      setState(() => _error = problem ?? 'New PINs do not match');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final AdminAuthResult r = await AccountLockScope.read(
        context,
      ).changePin(_current.text, _next.text);
      if (!mounted) return;
      switch (r.status) {
        case AdminAuthStatus.success:
          Navigator.pop(context, true);
        case AdminAuthStatus.wrongPin:
          _current.clear();
          setState(
            () => _error =
                'Current PIN is wrong. ${r.attemptsRemaining} attempt(s) left.',
          );
        case AdminAuthStatus.lockedOut:
        case AdminAuthStatus.noPin:
          // The account is locked now; its lock screen takes over.
          Navigator.pop(context, false);
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change account PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          PinField(
            key: const Key('changePin.current'),
            controller: _current,
            label: 'Current PIN',
            enabled: !_busy,
          ),
          const SizedBox(height: 12),
          PinField(
            key: const Key('changePin.new'),
            controller: _next,
            label: 'New PIN',
            enabled: !_busy,
          ),
          const SizedBox(height: 12),
          PinField(
            key: const Key('changePin.confirm'),
            controller: _again,
            label: 'Confirm new PIN',
            enabled: !_busy,
            onSubmitted: () => unawaited(_submit()),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('changePin.submit'),
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: const Text('Change PIN'),
        ),
      ],
    );
  }
}
