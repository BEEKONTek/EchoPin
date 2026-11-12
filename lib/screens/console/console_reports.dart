import 'dart:async';

import 'package:echo_pin/screens/console/console_screen.dart';
import 'package:echo_pin/screens/console/console_sessions.dart';
import 'package:echo_pin/widgets/ui_bits.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/material.dart';

/// Every report from every device, most urgent first.
class ReportsTab extends StatefulWidget {
  const ReportsTab({super.key});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  String _status = 'active';
  String? _category;
  int _generation = 0;

  static const Map<String, String> _statuses = <String, String>{
    'active': 'Needs attention',
    'open': 'Open',
    'investigating': 'Investigating',
    'resolved': 'Resolved',
    'dismissed': 'Dismissed',
    'all': 'All',
  };

  @override
  Widget build(BuildContext context) {
    final String query = <String>[
      'status=$_status',
      if (_category != null) 'category=$_category',
    ].join('&');
    return Column(
      children: <Widget>[
        // Filters in one row above the list.
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: <Widget>[
              for (final MapEntry<String, String> e in _statuses.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(e.value),
                    selected: _status == e.key,
                    onSelected: (_) => setState(() => _status = e.key),
                  ),
                ),
              const VerticalDivider(),
              for (final ReportCategory c in ReportCategory.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(c.wire),
                    selected: _category == c.wire,
                    onSelected: (bool on) =>
                        setState(() => _category = on ? c.wire : null),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ConsoleLoader(
            key: ValueKey<String>('$query/$_generation'),
            load: (BuildContext c) =>
                consoleApi(c, 'GET', '/v1/admin/reports?$query'),
            builder:
                (
                  BuildContext context,
                  Map<String, dynamic> data,
                  VoidCallback reload,
                ) {
                  final List<Map<String, dynamic>> reports =
                      (data['reports'] as List<dynamic>)
                          .cast<Map<String, dynamic>>();
                  return ConsoleList(
                    children: <Widget>[
                      if (reports.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(
                            child: Text('Nothing here. All clear.'),
                          ),
                        ),
                      for (final Map<String, dynamic> r in reports)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Tray(
                            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      ReportDetailScreen(id: r['id'] as String),
                                ),
                              );
                              if (mounted) setState(() => _generation++);
                            },
                            child: Row(
                              children: <Widget>[
                                Container(
                                  width: 4,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: severityColor(
                                      context,
                                      r['severity'] as String,
                                    ),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        r['subject'] as String,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${r['category']} · ${r['reporterName'] ?? 'deleted account'} · '
                                        '${consoleAgo(r['createdAt'])}'
                                        '${r['assignee'] == null ? '' : ' · ${r['assignee']}'}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: <Widget>[
                                    Pill(
                                      r['severity'] as String,
                                      color: severityColor(
                                        context,
                                        r['severity'] as String,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Pill(
                                      r['status'] as String,
                                      color: statusColor(
                                        context,
                                        r['status'] as String,
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

class ReportDetailScreen extends StatefulWidget {
  const ReportDetailScreen({super.key, required this.id});
  final String id;

  @override
  State<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends State<ReportDetailScreen> {
  final TextEditingController _note = TextEditingController();
  Map<String, dynamic>? _report;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await consoleApi(
        context,
        'GET',
        '/v1/admin/reports/${widget.id}',
      );
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _patch(Map<String, Object?> body) async {
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await consoleApi(
        context,
        'PATCH',
        '/v1/admin/reports/${widget.id}',
        body: body,
      );
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addNote() async {
    final String text = _note.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await consoleApi(
        context,
        'POST',
        '/v1/admin/reports/${widget.id}/notes',
        body: <String, Object?>{'body': text},
      );
      _note.clear();
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close(String status) async {
    final TextEditingController c = TextEditingController();
    final String? resolution = await showDialog<String>(
      context: context,
      builder: (BuildContext d) => AlertDialog(
        title: Text(status == 'resolved' ? 'Resolve report' : 'Dismiss report'),
        content: TextField(
          controller: c,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: ProtocolLimits.maxResolution,
          decoration: const InputDecoration(labelText: 'What was the outcome?'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, c.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    c.dispose();
    if (resolution == null || resolution.isEmpty) return;
    await _patch(<String, Object?>{'status': status, 'resolution': resolution});
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? r = _report;
    final ThemeData t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Report')),
      body: r == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Text(_error!),
            )
          : ConsoleList(
              maxWidth: 720,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    Pill(
                      r['severity'] as String,
                      color: severityColor(context, r['severity'] as String),
                    ),
                    Pill(
                      r['status'] as String,
                      color: statusColor(context, r['status'] as String),
                    ),
                    Pill(r['category'] as String),
                  ],
                ),
                const SizedBox(height: 12),
                Text(r['subject'] as String, style: t.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'From ${r['reporterName'] ?? 'a deleted account'} (${r['reporterEmail'] ?? '—'}) · '
                  '${r['device'] ?? 'unknown device'} · ${consoleDate(r['createdAt'])}',
                  style: t.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                Tray(child: SelectableText(r['body'] as String)),
                if (r['resolution'] != null) ...<Widget>[
                  const SectionLabel('Outcome'),
                  Tray(child: Text(r['resolution'] as String)),
                ],
                const SectionLabel('Actions'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _patch(<String, Object?>{
                                'assignToMe': true,
                                'status': 'investigating',
                              }),
                            ),
                      icon: const Icon(Icons.person_pin_outlined),
                      label: Text(
                        r['assignee'] == null
                            ? 'Take it'
                            : 'Assigned: ${r['assignee']}',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => unawaited(_close('resolved')),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Resolve'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => unawaited(_close('dismissed')),
                      icon: const Icon(Icons.do_not_disturb_on_outlined),
                      label: const Text('Dismiss'),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Change severity',
                      onSelected: (String s) =>
                          unawaited(_patch(<String, Object?>{'severity': s})),
                      itemBuilder: (_) => <PopupMenuEntry<String>>[
                        for (final ReportSeverity s in ReportSeverity.values)
                          PopupMenuItem<String>(
                            value: s.wire,
                            child: Text(s.wire),
                          ),
                      ],
                      child: const Chip(
                        avatar: Icon(Icons.tune, size: 16),
                        label: Text('Severity'),
                      ),
                    ),
                  ],
                ),
                if (r['sessionId'] != null) ...<Widget>[
                  const SectionLabel('Linked session'),
                  Tray(
                    onTap: () => unawaited(
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SessionDetailScreen(
                            sessionId: r['sessionId'] as String,
                          ),
                        ),
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.hub_outlined),
                        const SizedBox(width: 12),
                        Expanded(child: Text('Session ${r['sessionId']}')),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                  ),
                ],
                if (r['diagnostics'] is Map) ...<Widget>[
                  const SectionLabel('Attached diagnostics'),
                  Tray(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        for (final MapEntry<String, dynamic> e
                            in (r['diagnostics'] as Map<String, dynamic>)
                                .entries)
                          ListTile(
                            dense: true,
                            title: Text(e.key),
                            trailing: Text('${e.value}'),
                          ),
                      ],
                    ),
                  ),
                ],
                const SectionLabel('Internal notes'),
                for (final Map<String, dynamic> n
                    in (r['notes'] as List<dynamic>)
                        .cast<Map<String, dynamic>>())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Tray(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(n['body'] as String),
                          const SizedBox(height: 4),
                          Text(
                            '${n['author'] ?? '—'} · ${consoleAgo(n['createdAt'])}',
                            style: t.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                TextField(
                  controller: _note,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: ProtocolLimits.maxReportNote,
                  decoration: InputDecoration(
                    labelText: 'Add a note (not shown to the reporter)',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _busy ? null : () => unawaited(_addNote()),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
