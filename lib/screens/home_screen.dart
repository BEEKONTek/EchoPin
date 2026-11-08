// HOME SCREEN: where everything starts.
//
// Type your name, then create a session, join one with an invite code
// (typed, pasted or scanned from a QR), rejoin a recent one, or start the
// demo. When a server is configured and you are not signed in, starting a
// real session first asks you to sign in (the demo never does). The
// account icon opens sign-in / your account.
//
// _run() is the single place that starts a session: it shows progress,
// turns errors into friendly messages and opens SessionScreen on success.

import 'dart:async';

import 'package:echo_pin/account/account_provider.dart';
import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/models/session_summary.dart';
import 'package:echo_pin/providers/account_scope.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:echo_pin/providers/settings_provider.dart';
import 'package:echo_pin/providers/settings_scope.dart';
import 'package:echo_pin/screens/account/account_screen.dart';
import 'package:echo_pin/screens/account/sign_in_screen.dart';
import 'package:echo_pin/screens/admin/admin_gate_screen.dart';
import 'package:echo_pin/screens/qr_scan_screen.dart';
import 'package:echo_pin/screens/session_screen.dart';
import 'package:echo_pin/session/session_engine.dart';
import 'package:echo_pin/ui/format.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:echo_pin/widgets/animated_tray_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _sessionController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  Timer? _saveName;
  bool _busy = false;
  String? _nameError;
  String? _sessionError;
  String? _codeError;

  @override
  void initState() {
    super.initState();
    _nameController.text = SettingsScope.read(context).value.displayName;
    unawaited(SessionScope.read(context).loadHistory());
  }

  @override
  void dispose() {
    _saveName?.cancel();
    _nameController.dispose();
    _sessionController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // ── Display name ───────────────────────────────────────────────────────

  void _onNameChanged(String value) {
    _saveName?.cancel();
    String? error;
    if (value.trim().isNotEmpty) {
      try {
        validateDisplayName(value);
      } on InvalidInputError catch (e) {
        error = e.message;
      }
    }
    setState(() => _nameError = error);
    if (error != null) return;
    final SettingsProvider settings = SettingsScope.read(context);
    _saveName = Timer(const Duration(milliseconds: 400), () {
      final String clean = sanitizeName(value);
      final AppSettings current = settings.value;
      if (clean != current.displayName) {
        unawaited(settings.update(current.copyWith(displayName: clean)));
      }
    });
  }

  /// Saves any pending name edit right away, before a session starts.
  Future<void> _flushName() async {
    if (_saveName?.isActive ?? false) {
      _saveName!.cancel();
      final SettingsProvider settings = SettingsScope.read(context);
      final String clean = sanitizeName(_nameController.text);
      await settings.update(settings.value.copyWith(displayName: clean));
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────

  Future<void> _run(
    Future<Object?> Function(SessionProvider) start, {
    bool fromCode = false,
    bool live = true,
  }) async {
    if (_busy || _nameError != null) return;
    // With a server configured, live sessions need an account so the
    // emergency record has an owner. The demo never does.
    final AccountProvider account = AccountScope.read(context);
    if (live && account.enabled && !account.signedIn) {
      final bool ok = await SignInScreen.open(context);
      if (!ok || !mounted) return;
    }
    if (!mounted) return;
    final SessionProvider provider = SessionScope.read(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _codeError = null;
      _sessionError = null;
    });
    try {
      await _flushName();
      await start(provider);
    } on InvalidCodeError catch (e) {
      if (mounted) setState(() => _codeError = e.message);
      return;
    } on InvalidInputError catch (e) {
      if (mounted) {
        setState(() {
          if (fromCode) {
            _codeError = e.message;
          } else {
            _sessionError = e.message;
          }
        });
      }
      return;
    } on NoTransportError catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(e.message),
          action: SnackBarAction(
            label: 'Try demo',
            onPressed: () => _create(demo: true),
          ),
        ),
      );
      return;
    } on EchoError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(asEchoError(e).message)));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    _codeController.clear();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SessionScreen()));
  }

  void _create({bool demo = false}) {
    final String name = demo ? 'Demo session' : _sessionController.text;
    unawaited(
      _run(
        (SessionProvider p) =>
            p.createSession(name: name, forceSimulation: demo),
        live: !demo,
      ),
    );
  }

  void _join([String? raw]) {
    final String code = raw ?? _codeController.text;
    unawaited(
      _run((SessionProvider p) => p.joinWithCode(code), fromCode: true),
    );
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('The clipboard is empty')));
      return;
    }
    setState(() {
      _codeController.text = text;
      _codeError = null;
    });
  }

  Future<void> _scan() async {
    final String? raw = await QrScanScreen.open(context);
    if (raw == null || !mounted) return;
    _codeController.text = raw;
    _join(raw);
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final SessionProvider provider = SessionScope.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<SessionSummary> history = provider.history;
    final bool live = provider.canRunLiveSessions;
    final String? ended = provider.endedReason;
    final AccountProvider account = AccountScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('EchoPin'),
        actions: <Widget>[
          if (account.enabled)
            IconButton(
              key: const Key('home.account'),
              tooltip: account.signedIn ? 'Account' : 'Sign in',
              icon: Icon(
                account.signedIn
                    ? Icons.account_circle
                    : Icons.account_circle_outlined,
              ),
              onPressed: () => unawaited(openAccount(context)),
            ),
          IconButton(
            tooltip: 'Admin',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => unawaited(openAdmin(context)),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: <Widget>[
                const _Hero(),
                AnimatedSize(
                  duration: EchoTheme.medium,
                  curve: EchoTheme.enter,
                  child: !account.enabled || account.signedIn || !account.loaded
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _InfoTray(
                            icon: Icons.account_circle_outlined,
                            text:
                                account.signedOutReason ??
                                'Sign in to start or join live sessions. '
                                    'The demo works without an account.',
                          ),
                        ),
                ),
                AnimatedSize(
                  duration: EchoTheme.medium,
                  curve: EchoTheme.enter,
                  child: ended == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _InfoTray(
                            icon: Icons.timer_off_outlined,
                            text: ended,
                          ),
                        ),
                ),
                if (!live)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: _InfoTray(
                      icon: Icons.info_outline,
                      text:
                          'Live sessions need Bluetooth or Wi-Fi, which '
                          'browsers cannot use. Install the app to meet '
                          'people for real, or try the demo here.',
                    ),
                  ),
                TextField(
                  key: const Key('home.displayName'),
                  controller: _nameController,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.words,
                  maxLength: maxNameLength,
                  onChanged: _onNameChanged,
                  decoration: InputDecoration(
                    labelText: 'Your name',
                    helperText: _nameController.text.trim().isEmpty
                        ? 'Others will see you as “Guest”'
                        : 'Shown to people in your sessions',
                    errorText: _nameError,
                    counterText: '',
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 20),
                _Section(
                  title: 'Start a session',
                  children: <Widget>[
                    TextField(
                      key: const Key('home.name'),
                      controller: _sessionController,
                      enabled: !_busy && live,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.done,
                      maxLength: maxSessionNameLength,
                      onSubmitted: (_) => _create(),
                      decoration: InputDecoration(
                        labelText: 'Session name (optional)',
                        errorText: _sessionError,
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('home.create'),
                      onPressed: _busy || !live ? null : () => _create(),
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Create session'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'Join a session',
                  children: <Widget>[
                    TextField(
                      key: const Key('home.code'),
                      controller: _codeController,
                      enabled: !_busy && live,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.go,
                      autocorrect: false,
                      enableSuggestions: false,
                      onSubmitted: (_) => _join(),
                      onChanged: (_) {
                        if (_codeError != null) {
                          setState(() => _codeError = null);
                        }
                      },
                      decoration: InputDecoration(
                        labelText: 'Invite code',
                        hintText: 'ECHO-XXXX-XXXX-XXXX-XXXX-CC',
                        errorText: _codeError,
                        errorMaxLines: 2,
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              key: const Key('home.paste'),
                              tooltip: 'Paste',
                              icon: const Icon(Icons.content_paste),
                              onPressed: _busy || !live
                                  ? null
                                  : () => unawaited(_paste()),
                            ),
                            if (qrScanSupported)
                              IconButton(
                                key: const Key('home.scan'),
                                tooltip: 'Scan QR code',
                                icon: const Icon(Icons.qr_code_scanner),
                                onPressed: _busy || !live
                                    ? null
                                    : () => unawaited(_scan()),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('home.join'),
                      onPressed: _busy || !live ? null : () => _join(),
                      icon: const Icon(Icons.login),
                      label: const Text('Join session'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    key: const Key('home.demo'),
                    onPressed: _busy ? null : () => _create(demo: true),
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Try the demo (simulated people)'),
                  ),
                ),
                AnimatedSwitcher(
                  duration: EchoTheme.fast,
                  child: _busy
                      ? const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: LinearProgressIndicator(),
                        )
                      : const SizedBox.shrink(),
                ),
                AnimatedSize(
                  duration: EchoTheme.medium,
                  curve: EchoTheme.enter,
                  child: history.isEmpty
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 24, bottom: 8),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  'Recent sessions',
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                              TextButton(
                                onPressed: _busy
                                    ? null
                                    : () => unawaited(provider.clearHistory()),
                                child: const Text('Clear all'),
                              ),
                            ],
                          ),
                        ),
                ),
                AnimatedTrayList<SessionSummary>(
                  items: history,
                  keyOf: (SessionSummary s) => s.id,
                  itemBuilder: (BuildContext context, SessionSummary s) =>
                      _HistoryTray(
                        summary: s,
                        enabled: !_busy && live,
                        onTap: () =>
                            unawaited(_run((SessionProvider p) => p.rejoin(s))),
                        onForget: () =>
                            unawaited(provider.removeHistoryEntry(s.id)),
                      ),
                ),
                const SizedBox(height: 12),
                Text(
                  'No coordinates ever leave this device. Messages are '
                  'end-to-end encrypted for your session.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Row(
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              Icons.radar,
              color: theme.colorScheme.onPrimaryContainer,
              size: 30,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Stay together, privately',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'See your group relative to you, check in, and call for '
                  'help — over Bluetooth or Wi-Fi, no servers.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoTray extends StatelessWidget {
  const _InfoTray({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(EchoTheme.radius),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: <Widget>[
            Icon(icon, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryTray extends StatelessWidget {
  const _HistoryTray({
    required this.summary,
    required this.enabled,
    required this.onTap,
    required this.onForget,
  });

  final SessionSummary summary;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(EchoTheme.radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            children: <Widget>[
              Icon(Icons.history, color: scheme.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      summary.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Joined ${Fmt.ago(summary.lastJoinedAt)} · '
                      '${summary.boundaryRadiusMeters.round()} m boundary',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Forget',
                icon: const Icon(Icons.close, size: 18),
                onPressed: onForget,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
