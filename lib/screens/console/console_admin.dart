import 'dart:async';
import 'dart:convert';

import 'package:echo_pin/providers/account_scope.dart';
import 'package:echo_pin/screens/console/console_screen.dart';
import 'package:echo_pin/screens/console/console_sessions.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:echo_pin/widgets/ui_bits.dart';
import 'package:echopin_protocol/echopin_protocol.dart';
import 'package:flutter/material.dart';

// ── People ────────────────────────────────────────────────────────────────

class PeopleTab extends StatefulWidget {
  const PeopleTab({super.key});

  @override
  State<PeopleTab> createState() => _PeopleTabState();
}

class _PeopleTabState extends State<PeopleTab> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  String? _role;
  int _generation = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String qs = <String>[
      if (_query.isNotEmpty) 'q=${Uri.encodeQueryComponent(_query)}',
      if (_role != null) 'role=$_role',
    ].join('&');
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _search,
            maxLength: ProtocolLimits.maxSearchQuery,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Name or email',
              isDense: true,
              counterText: '',
            ),
            onSubmitted: (String v) => setState(() => _query = v.trim()),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            children: <Widget>[
              for (final String? r in <String?>[
                null,
                ...AccountRole.values.map((AccountRole r) => r.wire),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(r ?? 'everyone'),
                    selected: _role == r,
                    onSelected: (_) => setState(() => _role = r),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ConsoleLoader(
            key: ValueKey<String>('$qs/$_generation'),
            load: (BuildContext c) =>
                consoleApi(c, 'GET', '/v1/admin/accounts?limit=200&$qs'),
            builder:
                (
                  BuildContext context,
                  Map<String, dynamic> data,
                  VoidCallback reload,
                ) {
                  final List<Map<String, dynamic>> people =
                      (data['accounts'] as List<dynamic>)
                          .cast<Map<String, dynamic>>();
                  final ThemeData t = Theme.of(context);
                  return ConsoleList(
                    children: <Widget>[
                      if (people.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('Nobody matches.')),
                        ),
                      Tray(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: <Widget>[
                            for (final Map<String, dynamic> p in people)
                              ListTile(
                                onTap: () async {
                                  await Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          PersonScreen(id: p['id'] as String),
                                    ),
                                  );
                                  if (mounted) setState(() => _generation++);
                                },
                                title: Text(p['displayName'] as String),
                                subtitle: Text(
                                  '${p['email']} · ${p['devices']} device${p['devices'] == 1 ? '' : 's'}'
                                  '${p['totpEnabled'] == true ? ' · 2-step' : ''}',
                                  style: t.textTheme.bodySmall,
                                ),
                                trailing: Wrap(
                                  spacing: 6,
                                  children: <Widget>[
                                    if (p['role'] != 'member')
                                      Pill(
                                        p['role'] as String,
                                        color: t.colorScheme.primary,
                                      ),
                                    Pill(
                                      p['status'] as String,
                                      color: statusColor(
                                        context,
                                        p['status'] as String,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
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

class PersonScreen extends StatefulWidget {
  const PersonScreen({super.key, required this.id});
  final String id;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  int _generation = 0;

  Future<void> _act(Future<void> Function() action, String done) async {
    final ScaffoldMessengerState m = ScaffoldMessenger.of(context);
    try {
      await action();
      m.showSnackBar(SnackBar(content: Text(done)));
      if (mounted) setState(() => _generation++);
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  Future<bool> _confirm(String title, String body) async {
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
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final String? me = AccountScope.of(context).account?.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Person')),
      body: ConsoleLoader(
        key: ValueKey<int>(_generation),
        load: (BuildContext c) =>
            consoleApi(c, 'GET', '/v1/admin/accounts/${widget.id}'),
        builder: (BuildContext context, Map<String, dynamic> p, VoidCallback reload) {
          final ThemeData t = Theme.of(context);
          final bool self = p['id'] == me;
          final String path = '/v1/admin/accounts/${widget.id}';
          final DateTime? locked = p['lockedUntil'] is String
              ? DateTime.tryParse(p['lockedUntil'] as String)
              : null;
          final List<Map<String, dynamic>> devices =
              (p['deviceList'] as List<dynamic>).cast<Map<String, dynamic>>();
          final List<Map<String, dynamic>> sessions =
              (p['recentSessions'] as List<dynamic>)
                  .cast<Map<String, dynamic>>();
          final List<Map<String, dynamic>> reports =
              (p['recentReports'] as List<dynamic>)
                  .cast<Map<String, dynamic>>();
          return ConsoleList(
            maxWidth: 720,
            children: <Widget>[
              Text(p['displayName'] as String, style: t.textTheme.titleLarge),
              Text(
                '${p['email']} · joined ${consoleDate(p['createdAt'])} · last sign-in ${consoleAgo(p['lastLoginAt'])}',
                style: t.textTheme.bodySmall,
              ),
              if (locked != null && locked.isAfter(DateTime.now()))
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: NoticeTray(
                    icon: Icons.lock_clock,
                    color: EchoTheme.checkIn,
                    text:
                        'Locked after ${p['failedLogins']} wrong attempts until ${consoleDate(p['lockedUntil'])}.',
                  ),
                ),
              const SectionLabel('Role'),
              SegmentedButton<String>(
                segments: <ButtonSegment<String>>[
                  for (final AccountRole r in AccountRole.values)
                    ButtonSegment<String>(value: r.wire, label: Text(r.wire)),
                ],
                selected: <String>{p['role'] as String},
                onSelectionChanged: self
                    ? null
                    : (Set<String> s) => unawaited(
                        _act(
                          () => consoleApi(
                            context,
                            'PATCH',
                            path,
                            body: <String, Object?>{'role': s.single},
                          ),
                          'Role changed to ${s.single}',
                        ),
                      ),
              ),
              if (self)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Another admin has to change your own role or status.',
                    style: t.textTheme.bodySmall,
                  ),
                ),
              const SectionLabel('Access'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (!self && p['status'] == 'active')
                    OutlinedButton.icon(
                      icon: const Icon(Icons.block),
                      label: const Text('Switch off account'),
                      onPressed: () async {
                        if (!await _confirm(
                          'Switch off ${p['displayName']}?',
                          'They are signed out everywhere and cannot sign in until switched back on.',
                        )) {
                          return;
                        }
                        if (!context.mounted) return;
                        await _act(
                          () => consoleApi(
                            context,
                            'PATCH',
                            path,
                            body: <String, Object?>{'status': 'disabled'},
                          ),
                          'Account switched off',
                        );
                      },
                    ),
                  if (!self && p['status'] == 'disabled')
                    FilledButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Switch back on'),
                      onPressed: () => unawaited(
                        _act(
                          () => consoleApi(
                            context,
                            'PATCH',
                            path,
                            body: <String, Object?>{'status': 'active'},
                          ),
                          'Account switched on',
                        ),
                      ),
                    ),
                  if (locked != null)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.lock_open),
                      label: const Text('Unlock'),
                      onPressed: () => unawaited(
                        _act(
                          () => consoleApi(
                            context,
                            'PATCH',
                            path,
                            body: <String, Object?>{'unlock': true},
                          ),
                          'Unlocked',
                        ),
                      ),
                    ),
                  // For someone who lost the phone with their authenticator.
                  // Check who is asking first: this removes a protection.
                  if (p['totpEnabled'] == true)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.phonelink_erase),
                      label: const Text('Reset two-step'),
                      onPressed: () async {
                        if (!await _confirm(
                          'Reset two-step sign-in for ${p['displayName']}?',
                          'Only do this after confirming who is asking, for example in person '
                              'or on a known phone number. They can then sign in with just their '
                              'password and set up a new authenticator. They are signed out everywhere.',
                        )) {
                          return;
                        }
                        if (!context.mounted) return;
                        await _act(
                          () => consoleApi(
                            context,
                            'PATCH',
                            path,
                            body: <String, Object?>{'resetTwoStep': true},
                          ),
                          'Two-step sign-in reset',
                        );
                      },
                    ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out everywhere'),
                    onPressed: () async {
                      if (!await _confirm(
                        'Sign ${p['displayName']} out everywhere?',
                        'Every device has to sign in again.',
                      )) {
                        return;
                      }
                      if (!context.mounted) return;
                      await _act(
                        () => consoleApi(context, 'POST', '$path/sign-out'),
                        'Signed out everywhere',
                      );
                    },
                  ),
                ],
              ),
              const SectionLabel('Devices'),
              Tray(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    if (devices.isEmpty)
                      const ListTile(title: Text('No devices')),
                    for (final Map<String, dynamic> d in devices)
                      ListTile(
                        enabled: d['revokedAt'] == null,
                        title: Text(
                          '${d['label']} · EchoPin ${d['appVersion'] ?? '?'}',
                        ),
                        subtitle: Text(
                          d['revokedAt'] == null
                              ? 'Seen ${consoleAgo(d['lastSeenAt'])}'
                              : 'Removed ${consoleAgo(d['revokedAt'])}',
                        ),
                        trailing: d['revokedAt'] != null
                            ? null
                            : IconButton(
                                tooltip: 'Remove device',
                                icon: const Icon(Icons.phonelink_erase),
                                onPressed: () => unawaited(
                                  _act(
                                    () => consoleApi(
                                      context,
                                      'DELETE',
                                      '$path/devices/${d['id']}',
                                    ),
                                    'Device removed',
                                  ),
                                ),
                              ),
                      ),
                  ],
                ),
              ),
              const SectionLabel('Recent sessions'),
              Tray(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    if (sessions.isEmpty)
                      const ListTile(title: Text('None recorded')),
                    for (final Map<String, dynamic> s in sessions)
                      ListTile(
                        leading: Icon(
                          (s['sos'] as int) > 0
                              ? Icons.sos
                              : Icons.hub_outlined,
                          color: (s['sos'] as int) > 0 ? EchoTheme.sos : null,
                        ),
                        title: Text(s['sessionName'] as String),
                        subtitle: Text(consoleDate(s['startedAt'])),
                        onTap: () => unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SessionDetailScreen(
                                sessionId: s['sessionId'] as String,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SectionLabel('Reports filed'),
              Tray(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    if (reports.isEmpty) const ListTile(title: Text('None')),
                    for (final Map<String, dynamic> r in reports)
                      ListTile(
                        title: Text(r['subject'] as String),
                        subtitle: Text(
                          '${r['category']} · ${consoleAgo(r['createdAt'])}',
                        ),
                        trailing: Pill(
                          r['status'] as String,
                          color: statusColor(context, r['status'] as String),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Diagnostics ───────────────────────────────────────────────────────────

class DiagnosticsTab extends StatefulWidget {
  const DiagnosticsTab({super.key});

  @override
  State<DiagnosticsTab> createState() => _DiagnosticsTabState();
}

class _DiagnosticsTabState extends State<DiagnosticsTab> {
  String? _level;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            children: <Widget>[
              for (final String? l in <String?>[
                null,
                'error',
                'warning',
                'info',
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(l ?? 'all'),
                    selected: _level == l,
                    onSelected: (_) => setState(() => _level = l),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ConsoleLoader(
            key: ValueKey<String?>(_level),
            load: (BuildContext c) => consoleApi(
              c,
              'GET',
              '/v1/admin/diagnostics?limit=200${_level == null ? '' : '&level=$_level'}',
            ),
            builder:
                (
                  BuildContext context,
                  Map<String, dynamic> data,
                  VoidCallback reload,
                ) {
                  final List<Map<String, dynamic>> rows =
                      (data['diagnostics'] as List<dynamic>)
                          .cast<Map<String, dynamic>>();
                  return ConsoleList(
                    children: <Widget>[
                      if (rows.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('Nothing reported.')),
                        ),
                      for (final Map<String, dynamic> d in rows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Tray(
                            padding: EdgeInsets.zero,
                            child: ExpansionTile(
                              shape: const Border(),
                              leading: Icon(
                                switch (d['level']) {
                                  'error' => Icons.error_outline,
                                  'warning' => Icons.warning_amber,
                                  _ => Icons.info_outline,
                                },
                                color: statusColor(
                                  context,
                                  d['level'] as String,
                                ),
                              ),
                              title: Text(d['summary'] as String),
                              subtitle: Text(
                                '${d['email'] ?? '—'} · ${d['platform']} · EchoPin ${d['appVersion']} · '
                                '${consoleAgo(d['receivedAt'])}',
                              ),
                              children: <Widget>[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  child: SelectableText(
                                    const JsonEncoder.withIndent(
                                      '  ',
                                    ).convert(d['payload']),
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                  ),
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

// ── Audit ─────────────────────────────────────────────────────────────────

class AuditTab extends StatefulWidget {
  const AuditTab({super.key});

  @override
  State<AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<AuditTab> {
  Map<String, dynamic>? _verification;
  bool _verifying = false;

  Future<void> _verify() async {
    setState(() => _verifying = true);
    try {
      final Map<String, dynamic> v = await consoleApi(
        context,
        'GET',
        '/v1/admin/audit/verify',
      );
      if (mounted) setState(() => _verification = v);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? v = _verification;
    return ConsoleLoader(
      load: (BuildContext c) =>
          consoleApi(c, 'GET', '/v1/admin/audit?limit=300'),
      builder: (BuildContext context, Map<String, dynamic> data, VoidCallback reload) {
        final ThemeData t = Theme.of(context);
        final List<Map<String, dynamic>> entries =
            (data['entries'] as List<dynamic>).cast<Map<String, dynamic>>();
        return ConsoleList(
          children: <Widget>[
            Tray(
              child: Row(
                children: <Widget>[
                  Icon(
                    v == null
                        ? Icons.link
                        : (v['ok'] == true ? Icons.verified : Icons.link_off),
                    color: v == null
                        ? null
                        : (v['ok'] == true ? Colors.green : EchoTheme.sos),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      v == null
                          ? 'Every entry is chained to the one before it. Check that nothing was edited or removed.'
                          : v['ok'] == true
                          ? 'Intact: all ${v['checked']} entries check out.'
                          : 'BROKEN at entry ${v['brokenAtId']}: ${v['reason']}',
                    ),
                  ),
                  TextButton(
                    onPressed: _verifying ? null : () => unawaited(_verify()),
                    child: Text(_verifying ? 'Checking…' : 'Check chain'),
                  ),
                ],
              ),
            ),
            const SectionLabel('Newest first'),
            for (final Map<String, dynamic> e in entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Tray(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              e['action'] as String,
                              style: t.textTheme.titleSmall?.copyWith(
                                color:
                                    (e['action'] as String).contains(
                                          'unsealed',
                                        ) ||
                                        (e['action'] as String).contains(
                                          'reuse',
                                        )
                                    ? EchoTheme.sos
                                    : null,
                              ),
                            ),
                          ),
                          Text('#${e['id']}', style: t.textTheme.labelSmall),
                        ],
                      ),
                      Text(
                        '${e['actor']} · ${consoleDate(e['at'])}${e['ip'] == null ? '' : ' · ${e['ip']}'}',
                        style: t.textTheme.bodySmall,
                      ),
                      if ((e['detail'] as Map<String, dynamic>).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            (e['detail'] as Map<String, dynamic>).entries
                                .map(
                                  (MapEntry<String, dynamic> d) =>
                                      '${d.key}: ${d.value}',
                                )
                                .join(' · '),
                            style: t.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ── Backups ───────────────────────────────────────────────────────────────

class BackupsTab extends StatefulWidget {
  const BackupsTab({super.key});

  @override
  State<BackupsTab> createState() => _BackupsTabState();
}

class _BackupsTabState extends State<BackupsTab> {
  int _generation = 0;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    final ScaffoldMessengerState m = ScaffoldMessenger.of(context);
    try {
      final Map<String, dynamic> r = await consoleApi(
        context,
        'POST',
        '/v1/admin/backups',
      );
      m.showSnackBar(
        SnackBar(content: Text('Backup ${r['fileName']} written')),
      );
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text(errorText(e))));
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _generation++;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConsoleLoader(
      key: ValueKey<int>(_generation),
      load: (BuildContext c) => consoleApi(c, 'GET', '/v1/admin/backups'),
      builder: (BuildContext context, Map<String, dynamic> data, VoidCallback reload) {
        final ThemeData t = Theme.of(context);
        final List<Map<String, dynamic>> backups =
            (data['backups'] as List<dynamic>).cast<Map<String, dynamic>>();
        final bool busy = _running || data['running'] == true;
        return ConsoleList(
          maxWidth: 760,
          children: <Widget>[
            const NoticeTray(
              icon: Icons.info_outline,
              text:
                  'Backups run daily, are encrypted with the server’s backup key and '
                  'checked for tampering on restore. Sealed session records stay sealed '
                  'inside them. Restoring is done on the server with '
                  '`echopin_admin restore`, never from here.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : () => unawaited(_run()),
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.backup),
              label: Text(busy ? 'Backing up…' : 'Back up now'),
            ),
            const SectionLabel('History'),
            if (backups.isEmpty) const Tray(child: Text('No backups yet.')),
            for (final Map<String, dynamic> b in backups)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Tray(
                  child: Row(
                    children: <Widget>[
                      Icon(
                        b['status'] == 'ok'
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        color: statusColor(context, b['status'] as String),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              b['fileName'] as String? ?? '(${b['status']})',
                              style: t.textTheme.titleSmall,
                            ),
                            Text(
                              '${consoleDate(b['startedAt'])} · ${b['kind']}'
                              '${b['createdBy'] == null ? '' : ' by ${b['createdBy']}'}'
                              '${b['sizeBytes'] == null ? '' : ' · ${_size(b['sizeBytes'] as int)}'}'
                              '${b['status'] == 'pruned' ? ' · removed by retention' : ''}'
                              '${b['status'] == 'ok' && b['onDisk'] == false ? ' · file missing!' : ''}',
                              style: t.textTheme.bodySmall,
                            ),
                            if (b['error'] != null)
                              Text(
                                b['error'] as String,
                                style: TextStyle(
                                  color: t.colorScheme.error,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Pill(
                        b['status'] as String,
                        color: statusColor(context, b['status'] as String),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
