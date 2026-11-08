import 'dart:async';

import 'package:echo_pin/account/outbox.dart';
import 'package:echo_pin/models/session_summary.dart';
import 'package:echo_pin/providers/admin_scope.dart';
import 'package:echo_pin/providers/outbox_scope.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:echo_pin/widgets/ui_bits.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/material.dart';

/// "Report a problem": bugs, safety incidents, abuse, account trouble.
///
/// Reports go through the outbox, so they can be written with no signal
/// and are sent as soon as the device is back online.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, this.initialCategory});

  final ReportCategory? initialCategory;

  static Future<void> open(BuildContext context, {ReportCategory? category}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReportScreen(initialCategory: category)),
      );

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final TextEditingController _subject = TextEditingController();
  final TextEditingController _body = TextEditingController();
  late ReportCategory _category = widget.initialCategory ?? ReportCategory.bug;
  bool _urgent = false;
  bool _attachDiagnostics = true;
  bool _linkSession = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  /// The live session, else the most recent one.
  (String, String)? _session(SessionProvider p) {
    final String? live = p.session?.id;
    if (live != null) return (live, p.session!.name);
    final List<SessionSummary> h = p.history;
    if (h.isEmpty) return null;
    return (h.first.id, h.first.name);
  }

  Future<void> _send() async {
    final String subject = _subject.text.trim();
    final String body = _body.text.trim();
    if (subject.isEmpty || body.isEmpty) {
      setState(() => _error = 'Add a short title and say what happened');
      return;
    }
    final Outbox outbox = OutboxScope.read(context);
    final SessionProvider sessions = SessionScope.read(context);
    final Map<String, String> diagnostics = AdminScope.read(context).diagnostics();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState nav = Navigator.of(context);
    final (String, String)? session = _session(sessions);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await outbox.enqueue(OutboxKind.report, <String, dynamic>{
        'category': _category.wire,
        'severity': _category == ReportCategory.safety
            ? (_urgent ? ReportSeverity.critical.wire : ReportSeverity.high.wire)
            : ReportSeverity.normal.wire,
        'subject': subject,
        'body': body,
        if (_linkSession && session != null) 'sessionId': session.$1,
        if (_attachDiagnostics) 'diagnostics': diagnostics,
      });
      final bool sent = await outbox.flush();
      messenger.showSnackBar(SnackBar(
        content: Text(sent
            ? 'Report sent. You can follow it under Account → My reports'
            : 'Saved. It will be sent as soon as you are back online'),
      ));
      nav.pop();
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    final (String, String)? session = _session(SessionScope.of(context));
    final bool safety = _category == ReportCategory.safety;
    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: <Widget>[
                const SectionLabel('What is it about?'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final ReportCategory c in ReportCategory.values)
                      ChoiceChip(
                        key: Key('report.category.${c.wire}'),
                        label: Text(c.label),
                        selected: c == _category,
                        onSelected: (_) => setState(() => _category = c),
                      ),
                  ],
                ),
                AnimatedSize(
                  duration: EchoTheme.medium,
                  curve: EchoTheme.enter,
                  child: !safety
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Column(
                            children: <Widget>[
                              const NoticeTray(
                                icon: Icons.sos,
                                color: EchoTheme.sos,
                                text: 'If someone is in danger right now, hold SOS in your '
                                    'session and call local emergency services. A report '
                                    'is not an emergency call.',
                              ),
                              SwitchListTile(
                                key: const Key('report.urgent'),
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Someone may still be in danger'),
                                subtitle: const Text('Puts this at the top of every responder’s list'),
                                value: _urgent,
                                onChanged: (bool v) => setState(() => _urgent = v),
                              ),
                            ],
                          ),
                        ),
                ),
                const SectionLabel('Details'),
                TextField(
                  key: const Key('report.subject'),
                  controller: _subject,
                  maxLength: ProtocolLimits.maxReportSubject,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Short title', counterText: ''),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('report.body'),
                  controller: _body,
                  minLines: 5,
                  maxLines: 12,
                  maxLength: ProtocolLimits.maxReportBody,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'What happened?',
                    alignLabelWithHint: true,
                    hintText: safety
                        ? 'Who, where (roughly), when, and what you have already done'
                        : 'What you did, what you expected, what happened instead',
                  ),
                ),
                const SectionLabel('Attach'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('App diagnostics'),
                  subtitle: const Text('Version, radios and error counts. Never locations.'),
                  value: _attachDiagnostics,
                  onChanged: (bool v) => setState(() => _attachDiagnostics = v),
                ),
                if (session != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Link “${session.$2}”'),
                    subtitle: const Text('Lets a responder find that session’s sealed record'),
                    value: _linkSession,
                    onChanged: (bool v) => setState(() => _linkSession = v),
                  ),
                ErrorLine(_error),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('report.send'),
                  onPressed: _busy ? null : () => unawaited(_send()),
                  icon: const Icon(Icons.send),
                  label: const Text('Send report'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Reports go to your EchoPin administrators.',
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
