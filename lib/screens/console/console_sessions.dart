import 'dart:async';
import 'dart:convert';

import 'package:echo_pin/providers/account_scope.dart';
import 'package:echo_pin/screens/console/console_screen.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:echo_pin/widgets/ui_bits.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/material.dart';

/// The session index: metadata only. Opening a sealed log is a separate,
/// recorded step on the session's own screen.
class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _sosOnly = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String qs = <String>[
      if (_query.isNotEmpty) 'q=${Uri.encodeQueryComponent(_query)}',
      if (_sosOnly) 'sos=true',
    ].join('&');
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _search,
                  maxLength: ProtocolLimits.maxSearchQuery,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Session name, person or email',
                    isDense: true,
                    counterText: '',
                  ),
                  onSubmitted: (String v) => setState(() => _query = v.trim()),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                avatar: const Icon(Icons.sos, size: 16),
                label: const Text('SOS only'),
                selected: _sosOnly,
                onSelected: (bool v) => setState(() => _sosOnly = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: ConsoleLoader(
            key: ValueKey<String>(qs),
            load: (BuildContext c) =>
                consoleApi(c, 'GET', '/v1/admin/sessions?$qs'),
            builder:
                (
                  BuildContext context,
                  Map<String, dynamic> data,
                  VoidCallback reload,
                ) {
                  final List<Map<String, dynamic>> sessions =
                      (data['sessions'] as List<dynamic>)
                          .cast<Map<String, dynamic>>();
                  final ThemeData t = Theme.of(context);
                  return ConsoleList(
                    children: <Widget>[
                      if (sessions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('No sessions match.')),
                        ),
                      for (final Map<String, dynamic> s in sessions)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Tray(
                            onTap: () => unawaited(
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => SessionDetailScreen(
                                    sessionId: s['sessionId'] as String,
                                  ),
                                ),
                              ),
                            ),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  (s['sos'] as int) > 0
                                      ? Icons.sos
                                      : Icons.hub_outlined,
                                  color: (s['sos'] as int) > 0
                                      ? EchoTheme.sos
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Row(
                                        children: <Widget>[
                                          Flexible(
                                            child: Text(
                                              s['name'] as String,
                                              style: t.textTheme.titleSmall,
                                            ),
                                          ),
                                          if (s['finished'] ==
                                              false) ...<Widget>[
                                            const SizedBox(width: 8),
                                            const Pill(
                                              'live',
                                              color: EchoTheme.checkIn,
                                            ),
                                          ],
                                        ],
                                      ),
                                      Text(
                                        '${consoleDate(s['startedAt'])} · ${s['members']} people · '
                                        '${(s['people'] as List<dynamic>).join(', ')}',
                                        style: t.textTheme.bodySmall,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: <Widget>[
                                    if ((s['sos'] as int) > 0)
                                      Pill(
                                        '${s['sos']} SOS',
                                        color: EchoTheme.sos,
                                      ),
                                    if ((s['help'] as int) > 0)
                                      Pill(
                                        '${s['help']} need help',
                                        color: EchoTheme.checkIn,
                                      ),
                                    if (s['unproven'] == true)
                                      const Pill(
                                        'Upload from a non-member?',
                                        color: EchoTheme.sos,
                                      ),
                                    if ((s['timesOpened'] as int) > 0)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          'opened ${s['timesOpened']}×',
                                          style: t.textTheme.labelSmall,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
          ),
        ),
      ],
    );
  }
}

class SessionDetailScreen extends StatelessWidget {
  const SessionDetailScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Session $sessionId')),
      body: ConsoleLoader(
        load: (BuildContext c) => consoleApi(
          c,
          'GET',
          '/v1/admin/sessions/${Uri.encodeComponent(sessionId)}',
        ),
        builder: (BuildContext context, Map<String, dynamic> d, VoidCallback reload) {
          final ThemeData t = Theme.of(context);
          final List<Map<String, dynamic>> logs = (d['logs'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          final List<Map<String, dynamic>> access =
              (d['accessHistory'] as List<dynamic>)
                  .cast<Map<String, dynamic>>();
          return ConsoleList(
            maxWidth: 760,
            children: <Widget>[
              Text(d['name'] as String, style: t.textTheme.titleLarge),
              const SizedBox(height: 12),
              const NoticeTray(
                icon: Icons.lock_outline,
                text:
                    'Each member’s phone sends its own sealed record. Opening one '
                    'needs a reason and is recorded permanently in the audit log, '
                    'visible to every admin.',
              ),
              if (logs.any(
                (Map<String, dynamic> l) => l['tagsDisagree'] == true,
              ))
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: NoticeTray(
                    icon: Icons.help_outline,
                    text:
                        'Uploads disagree about who was in this session. Records marked '
                        '“Not proven a member” came from someone without the invite code. '
                        'Where too few people uploaded to tell, check with them directly.',
                  ),
                ),
              const SectionLabel('Records'),
              for (final Map<String, dynamic> l in logs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Tray(
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '${l['displayName'] ?? 'Deleted account'} · ${l['device'] ?? '?'}',
                                style: t.textTheme.titleSmall,
                              ),
                              Text(
                                '${l['final'] == true ? 'Final record' : 'Checkpoint ${l['sequence']}'} · '
                                'sent ${consoleAgo(l['receivedAt'])}'
                                '${l['endReason'] == null ? '' : ' · ${l['endReason']}'}',
                                style: t.textTheme.bodySmall,
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: <Widget>[
                                  if ((l['sos'] as int) > 0)
                                    Pill(
                                      '${l['sos']} SOS',
                                      color: EchoTheme.sos,
                                    ),
                                  if ((l['help'] as int) > 0)
                                    Pill(
                                      '${l['help']} need help',
                                      color: EchoTheme.checkIn,
                                    ),
                                  Pill(
                                    '${l['crossings'] ?? 0} boundary crossings',
                                  ),
                                  Pill('${l['members']} people'),
                                  if (l['doubleSealed'] == true)
                                    const Pill('Double-sealed'),
                                  // The upload's session tag doesn't match the
                                  // other members': whoever sent it may never
                                  // have been in this session.
                                  if (l['memberProven'] == false)
                                    const Pill(
                                      'Not proven a member',
                                      color: EchoTheme.sos,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: () =>
                              unawaited(_unseal(context, l, reload)),
                          icon: const Icon(Icons.lock_open, size: 18),
                          label: const Text('Open'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SectionLabel('Who has opened these records'),
              if (access.isEmpty) const Tray(child: Text('Nobody yet.')),
              for (final Map<String, dynamic> a in access)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Tray(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${a['by']} · ${consoleDate(a['at'])}',
                          style: t.textTheme.titleSmall,
                        ),
                        Text(
                          '“${a['reason']}”${a['caseRef'] == null ? '' : ' · case ${a['caseRef']}'}',
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _unseal(
    BuildContext context,
    Map<String, dynamic> log,
    VoidCallback reload,
  ) async {
    final ({String reason, String? caseRef})? why =
        await showDialog<({String reason, String? caseRef})>(
          context: context,
          builder: (_) => const _ReasonDialog(),
        );
    if (why == null || !context.mounted) return;
    try {
      final Map<String, dynamic> r = await consoleApi(
        context,
        'POST',
        '/v1/admin/session-logs/${log['id']}/unseal',
        body: <String, Object?>{
          'reason': why.reason,
          if (why.caseRef != null) 'caseRef': why.caseRef,
        },
      );
      reload();
      if (!context.mounted) return;
      Map<String, dynamic>? content = r['content'] as Map<String, dynamic>?;
      if (content == null && r['sealedInner'] != null) {
        // Double-sealed: the server removed its layer (audited); the inner
        // one opens only with a custodian key held on this device.
        content = await AccountScope.read(context).openInnerSeal(
          logId: log['id'] as String,
          custodianKeyId: r['custodianKeyId'] as String,
          sealedInner: base64.decode(r['sealedInner'] as String),
        );
        if (content == null) {
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            builder: (BuildContext c) => AlertDialog(
              title: const Text('Custodian key needed'),
              content: Text(
                'This record is double-sealed. The server has opened its layer (and '
                'recorded it), but the inside needs custodian key ${r['custodianKeyId']}, '
                'which is not on this device. Import it under the key icon at the top of '
                'the console, or ask a responder who has it.',
              ),
              actions: <Widget>[
                FilledButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
          return;
        }
      }
      if (!context.mounted || content == null) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SealedLogScreen(
            content: content!,
            recordedBy: '${log['displayName'] ?? '?'}',
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
    }
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final TextEditingController _reason = TextEditingController();
  final TextEditingController _case = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    _case.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool ok = _reason.text.trim().length >= 10;
    return AlertDialog(
      icon: const Icon(Icons.lock_open),
      title: const Text('Open a sealed record'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'Say why you need it. Your name, the time and this reason '
            'are recorded permanently and can be seen by every admin.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _reason,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            maxLength: ProtocolLimits.maxUnsealReason,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Reason',
              hintText: 'e.g. Member reported missing near the north trail',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _case,
            maxLength: ProtocolLimits.maxCaseRef,
            decoration: const InputDecoration(
              labelText: 'Case or incident number (optional)',
              counterText: '',
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: ok
              ? () => Navigator.pop(context, (
                  reason: _reason.text.trim(),
                  caseRef: _case.text.trim().isEmpty ? null : _case.text.trim(),
                ))
              : null,
          child: const Text('Open and record'),
        ),
      ],
    );
  }
}

/// A decrypted session record: who was there, their last known state, and
/// a timeline of everything the recording phone saw.
class SealedLogScreen extends StatelessWidget {
  const SealedLogScreen({
    super.key,
    required this.content,
    required this.recordedBy,
  });
  final Map<String, dynamic> content;
  final String recordedBy;

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    final List<Map<String, dynamic>> members =
        (content['members'] as List<dynamic>? ?? <dynamic>[])
            .cast<Map<String, dynamic>>();
    final List<Map<String, dynamic>> events =
        (content['events'] as List<dynamic>? ?? <dynamic>[])
            .cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(
        title: Text(content['sessionName'] as String? ?? 'Session record'),
      ),
      body: ConsoleList(
        maxWidth: 760,
        children: <Widget>[
          Text(
            'Recorded by $recordedBy’s phone · ${consoleDate(content['startedAt'])} → '
            '${content['endedAt'] == null ? 'still running at last upload' : consoleDate(content['endedAt'])}',
            style: t.textTheme.bodySmall,
          ),
          if (content['endReason'] != null)
            Text(
              'Ended: ${content['endReason']}',
              style: t.textTheme.bodySmall,
            ),
          if (content['truncated'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: NoticeTray(
                icon: Icons.content_cut,
                text:
                    'This record hit its size limit; later events were dropped.',
              ),
            ),
          SectionLabel(
            'Last known state (boundary ${content['boundaryMeters'] ?? '?'} m)',
          ),
          Tray(
            padding: EdgeInsets.zero,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const <DataColumn>[
                  DataColumn(label: Text('Person')),
                  DataColumn(label: Text('Last distance'), numeric: true),
                  DataColumn(label: Text('Measured')),
                  DataColumn(label: Text('Last heard')),
                  DataColumn(label: Text('At end')),
                ],
                rows: <DataRow>[
                  for (final Map<String, dynamic> m in members)
                    DataRow(
                      cells: <DataCell>[
                        DataCell(
                          Row(
                            children: <Widget>[
                              Text(m['name'] as String? ?? '?'),
                              if (m['verifiedInPerson'] == true)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(Icons.verified, size: 14),
                                ),
                            ],
                          ),
                        ),
                        DataCell(
                          Text(
                            m['lastDistanceMeters'] == null
                                ? '—'
                                : '${m['lastDistanceMeters']} m',
                          ),
                        ),
                        DataCell(Text(consoleDate(m['lastDistanceAt']))),
                        DataCell(Text(consoleDate(m['lastHeard']))),
                        DataCell(
                          Text(m['presentAtEnd'] == false ? 'left' : 'present'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Distances are estimated from Bluetooth signal strength, with privacy noise. '
              'No coordinates are ever recorded.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const SectionLabel('Timeline'),
          for (final Map<String, dynamic> e in events) _EventRow(event: e),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    final String type = event['type'] as String? ?? '?';
    final (IconData icon, Color? color, String text) = _describe(type, event);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Text(_time(event['at']), style: t.textTheme.labelSmall),
          ),
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  static String _time(Object? iso) {
    final DateTime? d = iso is String
        ? DateTime.tryParse(iso)?.toLocal()
        : null;
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  static (IconData, Color?, String) _describe(
    String type,
    Map<String, dynamic> e,
  ) {
    final String note = e['note'] == null ? '' : ' “${e['note']}”';
    switch (type) {
      case SessionLogEvent.started:
        return (
          Icons.play_arrow,
          null,
          'Session started (boundary ${e['boundaryMeters']} m)',
        );
      case SessionLogEvent.memberJoined:
        return (Icons.person_add_alt, null, '${e['name']} joined');
      case SessionLogEvent.memberLeft:
        return (Icons.person_remove_alt_1, null, '${e['name']} left');
      case SessionLogEvent.sosRaised:
        return (Icons.sos, EchoTheme.sos, '${e['by']} raised an SOS$note');
      case SessionLogEvent.sosResolved:
        return (
          Icons.health_and_safety,
          Colors.green,
          '${e['by']} is safe (SOS ended)',
        );
      case SessionLogEvent.pingSent:
        return (
          Icons.campaign_outlined,
          EchoTheme.checkIn,
          'Check-in sent to ${e['everyone'] == true ? 'everyone' : '${e['recipients']} people'}$note',
        );
      case SessionLogEvent.pingReceived:
        return (
          Icons.campaign_outlined,
          EchoTheme.checkIn,
          '${e['from']} asked for a check-in$note',
        );
      case SessionLogEvent.pingStatus:
        final String? response = e['response'] as String?;
        return (
          response == 'Need help' ? Icons.warning_amber : Icons.reply,
          response == 'Need help' ? EchoTheme.sos : null,
          response == null
              ? '${e['name']}: ${e['state']}'
              : '${e['name']} answered “$response”',
        );
      case SessionLogEvent.pingAnswered:
        return (
          Icons.reply,
          e['response'] == 'Need help' ? EchoTheme.sos : null,
          'Answered ${e['to']}: “${e['response']}”',
        );
      case SessionLogEvent.leftBoundary:
        return (
          Icons.logout,
          EchoTheme.checkIn,
          '${e['name']} went outside the boundary (~${e['distanceMeters']} m)',
        );
      case SessionLogEvent.returnedToBoundary:
        return (
          Icons.login,
          null,
          '${e['name']} came back inside (~${e['distanceMeters']} m)',
        );
      case SessionLogEvent.security:
        return (Icons.gpp_maybe, EchoTheme.sos, 'Security: ${e['message']}');
      case SessionLogEvent.ended:
        return (Icons.stop, null, 'Ended: ${e['reason']}');
      default:
        return (Icons.circle_outlined, null, type);
    }
  }
}
