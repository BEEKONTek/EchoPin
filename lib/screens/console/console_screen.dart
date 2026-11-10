import 'dart:async';
import 'dart:math' as math;

import 'package:echo_pin/account/account_models.dart';
import 'package:echo_pin/providers/account_scope.dart';
import 'package:echo_pin/screens/account/account_lock_gate.dart';
import 'package:echo_pin/screens/console/console_admin.dart';
import 'package:echo_pin/screens/console/console_reports.dart';
import 'package:echo_pin/screens/console/console_sessions.dart';
import 'package:echo_pin/ui/format.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:echo_pin/widgets/ui_bits.dart';
import 'package:flutter/material.dart';

/// Calls the server as the signed-in console user.
Future<Map<String, dynamic>> consoleApi(
  BuildContext context,
  String method,
  String path, {
  Object? body,
}) => AccountScope.read(context).authed(method, path, body: body);

String consoleAgo(Object? iso) {
  final DateTime? t = iso is String ? DateTime.tryParse(iso) : null;
  return t == null ? '—' : Fmt.ago(t.toLocal());
}

String consoleDate(Object? iso) {
  final DateTime? t = iso is String ? DateTime.tryParse(iso)?.toLocal() : null;
  if (t == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

class _Tab {
  const _Tab(this.label, this.icon, this.builder);
  final String label;
  final IconData icon;
  final WidgetBuilder builder;
}

/// Central console for responders and admins: everything across every
/// device and session, in one place.
class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key});

  /// Opens behind the account lock (see AccountLockGuard).
  static Future<void> open(BuildContext context) =>
      pushLocked<void>(context, const ConsoleScreen());

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  int _index = 0;

  List<_Tab> _tabs(Account me) => <_Tab>[
    _Tab('Overview', Icons.dashboard_outlined, (_) => const OverviewTab()),
    _Tab('Reports', Icons.flag_outlined, (_) => const ReportsTab()),
    _Tab('Sessions', Icons.hub_outlined, (_) => const SessionsTab()),
    if (me.isAdmin) ...<_Tab>[
      _Tab('People', Icons.people_outline, (_) => const PeopleTab()),
      _Tab('Diagnostics', Icons.monitor_heart_outlined, (_) => const DiagnosticsTab()),
      _Tab('Audit', Icons.receipt_long_outlined, (_) => const AuditTab()),
      _Tab('Backups', Icons.backup_outlined, (_) => const BackupsTab()),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final Account? me = AccountScope.of(context).account;
    if (me == null || !me.canUseConsole) {
      return Scaffold(
        appBar: AppBar(title: const Text('Console')),
        body: const Center(child: Text('Your account does not have console access.')),
      );
    }
    final List<_Tab> tabs = _tabs(me);
    final int index = _index.clamp(0, tabs.length - 1);
    final bool wide = MediaQuery.sizeOf(context).width >= 840;
    final Widget body = KeyedSubtree(
      key: ValueKey<String>(tabs[index].label),
      child: tabs[index].builder(context),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(tabs[index].label),
        actions: <Widget>[
          IconButton(
            key: const ValueKey<String>('console.custodian'),
            tooltip: 'Custodian key',
            icon: const Icon(Icons.key_outlined),
            onPressed: () => unawaited(showDialog<void>(
              context: context,
              builder: (_) => const _CustodianDialog(),
            )),
          ),
        ],
      ),
      body: wide
          ? Row(
              children: <Widget>[
                NavigationRail(
                  selectedIndex: index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (int i) => setState(() => _index = i),
                  destinations: <NavigationRailDestination>[
                    for (final _Tab t in tabs)
                      NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index,
              labelBehavior: tabs.length > 5
                  ? NavigationDestinationLabelBehavior.onlyShowSelected
                  : NavigationDestinationLabelBehavior.alwaysShow,
              onDestinationSelected: (int i) => setState(() => _index = i),
              destinations: <NavigationDestination>[
                for (final _Tab t in tabs)
                  NavigationDestination(icon: Icon(t.icon), label: t.label),
              ],
            ),
    );
  }
}

/// Loads with [load], shows a spinner, an error with retry, or [builder].
/// Pull to refresh re-runs [load].
class ConsoleLoader extends StatefulWidget {
  const ConsoleLoader({super.key, required this.load, required this.builder});

  final Future<Map<String, dynamic>> Function(BuildContext context) load;
  final Widget Function(BuildContext context, Map<String, dynamic> data, VoidCallback reload) builder;

  @override
  State<ConsoleLoader> createState() => _ConsoleLoaderState();
}

class _ConsoleLoaderState extends State<ConsoleLoader> {
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load(context);
  }

  // Block body on purpose: `setState(() => _future = …)` would return the
  // Future from the closure, which Flutter rejects (debug builds throw,
  // which aborted the console right after a break-glass opening).
  void _reload() {
    final Future<Map<String, dynamic>> next = widget.load(context);
    setState(() {
      _future = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Map<String, dynamic>> snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.cloud_off_outlined, size: 40),
                  const SizedBox(height: 12),
                  Text(errorText(snap.error!), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _reload, child: const Text('Try again')),
                ],
              ),
            ),
          );
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        return RefreshIndicator(
          onRefresh: () async {
            _reload();
            await _future.catchError((Object _) => <String, dynamic>{});
          },
          child: widget.builder(context, snap.data!, _reload),
        );
      },
    );
  }
}

/// Centered, width-limited scrolling column used by every tab.
class ConsoleList extends StatelessWidget {
  const ConsoleList({super.key, required this.children, this.maxWidth = 960});
  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: children,
        ),
      ),
    );
  }
}

// ── Overview ───────────────────────────────────────────────────────────────

class OverviewTab extends StatelessWidget {
  const OverviewTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ConsoleLoader(
      load: (BuildContext c) => consoleApi(c, 'GET', '/v1/admin/overview'),
      builder: (BuildContext context, Map<String, dynamic> o, VoidCallback reload) {
        final Map<String, dynamic> accounts = o['accounts'] as Map<String, dynamic>;
        final Map<String, dynamic> reports = o['reports'] as Map<String, dynamic>;
        final Map<String, dynamic> sessions = o['sessions'] as Map<String, dynamic>;
        final Map<String, dynamic> diag = o['diagnostics24h'] as Map<String, dynamic>;
        final Map<String, dynamic>? backup = o['lastBackup'] as Map<String, dynamic>?;
        final List<Map<String, dynamic>> daily =
            (o['daily'] as List<dynamic>).cast<Map<String, dynamic>>();
        final List<Map<String, dynamic>> versions =
            (o['versions'] as List<dynamic>).cast<Map<String, dynamic>>();
        final ColorScheme s = Theme.of(context).colorScheme;
        final int critical = reports['critical'] as int;
        final int errors = diag['errors'] as int;
        final bool backupStale = backup == null ||
            backup['status'] != 'ok' ||
            DateTime.now().difference(DateTime.parse(backup['startedAt'] as String)) >
                const Duration(hours: 36);

        return ConsoleList(
          children: <Widget>[
            if (critical > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: NoticeTray(
                  icon: Icons.sos,
                  color: EchoTheme.sos,
                  text: '$critical critical report${critical == 1 ? '' : 's'} open. '
                      'Someone may be in danger. Open Reports.',
                ),
              ),
            if (backupStale)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: NoticeTray(
                  icon: Icons.backup_outlined,
                  color: EchoTheme.checkIn,
                  text: backup == null
                      ? 'No backup has been taken yet.'
                      : backup['status'] == 'ok'
                      ? 'The last backup is more than a day and a half old.'
                      : 'The last backup failed: ${backup['error'] ?? 'unknown error'}',
                ),
              ),
            _TileGrid(
              tiles: <_Stat>[
                _Stat('Open reports', '${reports['open']}',
                    critical > 0 ? '$critical critical' : 'none critical',
                    critical > 0 ? EchoTheme.sos : null, Icons.flag_outlined),
                _Stat('Sessions', '${sessions['last24h']}', '${sessions['last7d']} this week', null, Icons.hub_outlined),
                _Stat('SOS sessions', '${sessions['withSos7d']}', 'in the last 7 days',
                    (sessions['withSos7d'] as int) > 0 ? EchoTheme.sos : null, Icons.sos),
                _Stat('People', '${accounts['active']}',
                    '${accounts['pending']} unverified · ${accounts['disabled']} off', null, Icons.people_outline),
                _Stat('Devices online', '${o['devicesActive24h']}', 'seen in 24 h', null, Icons.devices),
                _Stat('App errors', '$errors', '${diag['warnings']} warnings · 24 h',
                    errors > 0 ? s.error : null, Icons.error_outline),
              ],
            ),
            const SectionLabel('Last 14 days'),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final List<Widget> charts = <Widget>[
                  _DailyBars(title: 'Sessions per day', days: daily, field: 'sessions', color: s.primary),
                  _DailyBars(title: 'Sessions with an SOS', days: daily, field: 'sos', color: EchoTheme.sos),
                  _DailyBars(title: 'App errors', days: daily, field: 'errors', color: s.error),
                  _DailyBars(title: 'Reports filed', days: daily, field: 'reports', color: s.tertiary),
                ];
                final int columns = c.maxWidth >= 720 ? 2 : 1;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    for (final Widget w in charts)
                      SizedBox(width: (c.maxWidth - 12 * (columns - 1)) / columns, child: w),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            _DailyTable(days: daily),
            const SectionLabel('App versions in use (30 days)'),
            Tray(
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  if (versions.isEmpty)
                    const ListTile(title: Text('No devices yet')),
                  for (final Map<String, dynamic> v in versions)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.phone_android),
                      title: Text('${v['platform']} · EchoPin ${v['appVersion']}'),
                      trailing: Text('${v['devices']} device${v['devices'] == 1 ? '' : 's'}'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Updated ${consoleAgo(o['generatedAt'])}. Pull down to refresh.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

class _Stat {
  const _Stat(this.label, this.value, this.detail, this.accent, this.icon);
  final String label;
  final String value;
  final String detail;
  final Color? accent;
  final IconData icon;
}

class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles});
  final List<_Stat> tiles;

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final int columns = c.maxWidth >= 720 ? 3 : 2;
        final double w = (c.maxWidth - 10 * (columns - 1)) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            for (final _Stat s in tiles)
              SizedBox(
                width: w,
                child: Tray(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(s.icon, size: 16, color: s.accent ?? t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(s.label, style: t.textTheme.labelMedium, overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // The number wears text ink; the icon carries the accent.
                      Text(s.value, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
                      Text(s.detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
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

/// One series per chart (small multiples, never a dual axis). Bars have a
/// rounded data end, square baseline, a 2 px gap, and a tooltip per day.
class _DailyBars extends StatelessWidget {
  const _DailyBars({required this.title, required this.days, required this.field, required this.color});
  final String title;
  final List<Map<String, dynamic>> days;
  final String field;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    final List<int> values = days.map((Map<String, dynamic> d) => d[field] as int).toList();
    final int maxV = values.fold(0, math.max);
    final int total = values.fold(0, (int a, int b) => a + b);
    return Tray(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(title, style: t.textTheme.titleSmall)),
              Text('$total total', style: t.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 72,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                for (int i = 0; i < values.length; i++)
                  Expanded(
                    child: Tooltip(
                      message: '${_day(days[i]['day'])}: ${values[i]}',
                      child: Semantics(
                        label: '${_day(days[i]['day'])}, ${values[i]}',
                        child: Container(
                          // Whole column is the hit target, bigger than the mark.
                          color: Colors.transparent,
                          alignment: Alignment.bottomCenter,
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          child: Container(
                            height: maxV == 0 ? 1 : math.max(values[i] == 0 ? 1.0 : 3.0, 72.0 * values[i] / maxV),
                            decoration: BoxDecoration(
                              color: values[i] == 0 ? t.colorScheme.outlineVariant : color,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: t.colorScheme.outlineVariant),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Text(_day(days.first['day']), style: t.textTheme.labelSmall),
              const Spacer(),
              Text('today', style: t.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}

String _day(Object? iso) {
  final DateTime? d = iso is String ? DateTime.tryParse(iso) : null;
  if (d == null) return '';
  const List<String> m = <String>['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]}';
}

/// The same numbers as a table, for screen readers and exact values.
class _DailyTable extends StatelessWidget {
  const _DailyTable({required this.days});
  final List<Map<String, dynamic>> days;

  @override
  Widget build(BuildContext context) {
    return Tray(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        title: const Text('Show as table'),
        shape: const Border(),
        children: <Widget>[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const <DataColumn>[
                DataColumn(label: Text('Day')),
                DataColumn(label: Text('Sessions'), numeric: true),
                DataColumn(label: Text('With SOS'), numeric: true),
                DataColumn(label: Text('Errors'), numeric: true),
                DataColumn(label: Text('Reports'), numeric: true),
              ],
              rows: <DataRow>[
                for (final Map<String, dynamic> d in days.reversed)
                  DataRow(cells: <DataCell>[
                    DataCell(Text(_day(d['day']))),
                    DataCell(Text('${d['sessions']}')),
                    DataCell(Text('${d['sos']}')),
                    DataCell(Text('${d['errors']}')),
                    DataCell(Text('${d['reports']}')),
                  ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}



/// Custodian keys on this device: needed to open double-sealed records.
///
/// The key never leaves the device and is never sent to the server; that
/// is the point of it. Only responders who must open records in an
/// emergency should import it.
class _CustodianDialog extends StatefulWidget {
  const _CustodianDialog();

  @override
  State<_CustodianDialog> createState() => _CustodianDialogState();
}

class _CustodianDialogState extends State<_CustodianDialog> {
  final TextEditingController _key = TextEditingController();
  List<String> _ids = const <String>[];
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final List<String> ids = await AccountScope.read(context).custodianKeyIds();
    if (mounted) setState(() => _ids = ids);
  }

  Future<void> _import() async {
    try {
      final String id = await AccountScope.read(context).importCustodianKey(_key.text);
      _key.clear();
      setState(() {
        _error = null;
        _info = 'Imported key $id. Double-sealed records sealed to it now open here.';
      });
      await _load();
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Custodian key'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Double-sealed records need this key as well as the server. It stays on '
              'this device and is never uploaded. Import it only on devices of people '
              'who must open records in an emergency.',
            ),
            const SizedBox(height: 12),
            if (_ids.isEmpty) const Text('No custodian key on this device.'),
            for (final String id in _ids)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key),
                title: Text(id, style: const TextStyle(fontFamily: 'monospace')),
                trailing: IconButton(
                  tooltip: 'Remove from this device',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await AccountScope.read(context).removeCustodianKey(id);
                    await _load();
                  },
                ),
              ),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'ECHOPIN-CUSTODIAN-1:…'),
            ),
            if (_info != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_info!)),
            ErrorLine(_error),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(onPressed: () => unawaited(_import()), child: const Text('Import')),
      ],
    );
  }
}
