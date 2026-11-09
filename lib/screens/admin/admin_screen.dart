import 'dart:async';

import 'package:echo_pin/models/admin_event.dart';
import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/providers/admin_provider.dart';
import 'package:echo_pin/providers/admin_scope.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:echo_pin/services/admin_auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Admin panel: diagnostics, settings, synthetic peers, data tools, audit
/// log. Every action goes through [AdminProvider], which refuses when
/// locked, so this screen holds no authorization logic of its own.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AdminProvider admin = AdminScope.of(context);

    if (!admin.isUnlocked) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.lock_outline, size: 48),
              const SizedBox(height: 12),
              const Text('Admin is locked.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    }

    return Listener(
      // Any touch postpones auto-lock.
      onPointerDown: (_) => admin.touch(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Admin'),
          actions: <Widget>[
            IconButton(
              key: const Key('admin.lock'),
              tooltip: 'Lock',
              icon: const Icon(Icons.lock),
              onPressed: () {
                admin.lock();
                Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: const <Widget>[
                _DiagnosticsCard(),
                _SettingsCard(),
                _SyntheticPeersCard(),
                _DataCard(),
                _AuditLogCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.children,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

// ── Diagnostics ──────────────────────────────────────────────────────────

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard();

  @override
  Widget build(BuildContext context) {
    final AdminProvider admin = AdminScope.of(context);
    final Map<String, String> d = admin.diagnostics();
    final TextTheme text = Theme.of(context).textTheme;
    return _Section(
      title: 'Diagnostics',
      icon: Icons.monitor_heart_outlined,
      trailing: IconButton(
        tooltip: 'Copy report',
        icon: const Icon(Icons.copy, size: 20),
        onPressed: () async {
          final String report = d.entries
              .map((MapEntry<String, String> e) => '${e.key}: ${e.value}')
              .join('\n');
          await Clipboard.setData(ClipboardData(text: report));
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Diagnostics copied')));
        },
      ),
      children: <Widget>[
        for (final MapEntry<String, String> e in d.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(width: 140, child: Text(e.key, style: text.bodySmall)),
                Expanded(child: Text(e.value, style: text.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}

// ── Settings ─────────────────────────────────────────────────────────────

class _SettingsCard extends StatelessWidget {
  const _SettingsCard();

  @override
  Widget build(BuildContext context) {
    final AdminProvider admin = AdminScope.of(context);
    final AppSettings s = admin.settings;
    void save(AppSettings next) => unawaited(admin.updateSettings(next));

    return _Section(
      title: 'Settings',
      icon: Icons.tune,
      children: <Widget>[
        Text('Default boundary: ${s.defaultBoundaryRadiusMeters.round()} m'),
        Slider(
          key: const Key('admin.radius'),
          value: s.defaultBoundaryRadiusMeters,
          min: AppSettings.minRadius,
          max: AppSettings.maxRadius,
          divisions: 18,
          label: '${s.defaultBoundaryRadiusMeters.round()} m',
          onChanged: (double v) =>
              save(s.copyWith(defaultBoundaryRadiusMeters: v)),
        ),
        Text('Privacy noise: ±${s.noiseSigmaMeters.round()} m'),
        Slider(
          key: const Key('admin.noise'),
          value: s.noiseSigmaMeters,
          min: AppSettings.minNoise,
          max: AppSettings.maxNoise,
          divisions: 50,
          label: '±${s.noiseSigmaMeters.round()} m',
          onChanged: (double v) => save(s.copyWith(noiseSigmaMeters: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Boundary alerts'),
          value: s.alertsEnabled,
          onChanged: (bool v) => save(s.copyWith(alertsEnabled: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('OS notifications'),
          subtitle: Text(admin.platform.notificationBackend),
          value: s.osNotificationsEnabled,
          onChanged: s.alertsEnabled
              ? (bool v) => save(s.copyWith(osNotificationsEnabled: v))
              : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Haptics'),
          value: s.hapticsEnabled,
          onChanged: (bool v) => save(s.copyWith(hapticsEnabled: v)),
        ),
        SwitchListTile(
          key: const Key('admin.bluetooth'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Bluetooth radio'),
          subtitle: const Text('Offline discovery, distance and messages'),
          value: s.bluetoothEnabled,
          onChanged: (bool v) => save(s.copyWith(bluetoothEnabled: v)),
        ),
        SwitchListTile(
          key: const Key('admin.wifi'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Wi-Fi radio'),
          subtitle: const Text('Same network or hotspot; no distance'),
          value: s.wifiEnabled,
          onChanged: (bool v) => save(s.copyWith(wifiEnabled: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Force simulation'),
          subtitle: const Text('New sessions use simulated people only'),
          value: s.forceSimulation,
          onChanged: (bool v) => save(s.copyWith(forceSimulation: v)),
        ),
        Text(
          'Radio changes apply to the next session.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

// ── Synthetic peers ──────────────────────────────────────────────────────

class _SyntheticPeersCard extends StatefulWidget {
  const _SyntheticPeersCard();

  @override
  State<_SyntheticPeersCard> createState() => _SyntheticPeersCardState();
}

class _SyntheticPeersCardState extends State<_SyntheticPeersCard> {
  final TextEditingController _label = TextEditingController();
  double _bearing = 45;
  double _distance = 40;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AdminProvider admin = AdminScope.of(context);
    final SessionProvider sessions = SessionScope.of(context);
    final bool active = sessions.hasSession;
    final List<PeerPresence> synthetic = sessions.syntheticPeers;

    return _Section(
      title: 'Synthetic peers',
      icon: Icons.science_outlined,
      children: <Widget>[
        if (!active)
          const Text('Start or join a session to inject test peers.')
        else ...<Widget>[
          const Text(
            'Injected peers flow through noise, crossing detection and '
            'alerts exactly like real ones. Re-inject an existing peer to '
            'move it across the boundary.',
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('admin.peerLabel'),
            controller: _label,
            decoration: const InputDecoration(
              labelText: 'Label (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Text('Bearing ${_bearing.round()}°'),
          Slider(
            value: _bearing,
            max: 359,
            onChanged: (double v) => setState(() => _bearing = v),
          ),
          Text('Distance ${_distance.round()} m'),
          Slider(
            value: _distance,
            max: AppSettings.maxRadius,
            onChanged: (double v) => setState(() => _distance = v),
          ),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: const Key('admin.inject'),
                icon: const Icon(Icons.add),
                label: const Text('Inject'),
                onPressed: () {
                  admin.injectPeer(
                    label: _label.text,
                    bearingDegrees: _bearing,
                    distanceMeters: _distance,
                  );
                  _label.clear();
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.shuffle),
                label: const Text('Random'),
                onPressed: admin.injectRandomPeer,
              ),
            ],
          ),
          for (final PeerPresence p in synthetic)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.science_outlined),
              title: Text(p.label),
              subtitle: Text(
                '${p.bearingDegrees.round()}° · ${p.distanceMeters.round()} m '
                '(before noise)',
              ),
              trailing: Wrap(
                children: <Widget>[
                  IconButton(
                    tooltip: 'Move to slider position',
                    icon: const Icon(Icons.open_with),
                    onPressed: () => admin.injectPeer(
                      id: p.id,
                      label: p.label,
                      bearingDegrees: _bearing,
                      distanceMeters: _distance,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => admin.removePeer(p.id),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

// ── Data & security ──────────────────────────────────────────────────────

class _DataCard extends StatelessWidget {
  const _DataCard();

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final AdminProvider admin = AdminScope.of(context);
    final SessionProvider sessions = SessionScope.of(context);

    return _Section(
      title: 'Data & security',
      icon: Icons.security,
      children: <Widget>[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history),
          title: const Text('Clear session history'),
          subtitle: Text('${sessions.history.length} saved'),
          onTap: () async {
            if (!await _confirm(
              context,
              'Clear history?',
              'Removes every saved session code from this device.',
            )) {
              return;
            }
            await admin.clearHistory();
            if (context.mounted) _snack(context, 'History cleared');
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.restart_alt),
          title: const Text('Reset settings to defaults'),
          onTap: () async {
            if (!await _confirm(
              context,
              'Reset settings?',
              'Radius, noise, alert and simulation settings return to '
                  'their defaults.',
            )) {
              return;
            }
            await admin.resetSettings();
            if (context.mounted) _snack(context, 'Settings reset');
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.password),
          title: const Text('Change PIN'),
          onTap: () => unawaited(
            showDialog<void>(
              context: context,
              builder: (_) => _ChangePinDialog(admin: admin),
            ),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.no_encryption_gmailerrorred,
            color: Theme.of(context).colorScheme.error,
          ),
          title: const Text('Remove admin PIN'),
          subtitle: const Text('Locks now; the next visit sets a new PIN'),
          onTap: () async {
            if (!await _confirm(
              context,
              'Remove admin PIN?',
              'Anyone with this device can then create a new PIN.',
            )) {
              return;
            }
            await admin.removePin();
            if (context.mounted) await Navigator.of(context).maybePop();
          },
        ),
      ],
    );
  }
}

class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog({required this.admin});
  final AdminProvider admin;

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String? problem = AdminAuthService.validatePin(_next.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() => _busy = true);
    final AdminAuthResult r = await widget.admin.changePin(
      _current.text,
      _next.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    switch (r.status) {
      case AdminAuthStatus.success:
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('PIN changed')));
      case AdminAuthStatus.wrongPin:
        setState(
          () => _error =
              'Current PIN is wrong (${r.attemptsRemaining} attempts left)',
        );
      case AdminAuthStatus.lockedOut:
      case AdminAuthStatus.noPin:
        Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label) =>
        InputDecoration(labelText: label, border: const OutlineInputBorder());
    final List<TextInputFormatter> digits = <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(AdminAuthService.maxPinLength),
    ];
    return AlertDialog(
      title: const Text('Change PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _current,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: digits,
            decoration: deco('Current PIN'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _next,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: digits,
            decoration: deco('New PIN'),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: const Text('Change'),
        ),
      ],
    );
  }
}

// ── Audit log ────────────────────────────────────────────────────────────

class _AuditLogCard extends StatelessWidget {
  const _AuditLogCard();

  @override
  Widget build(BuildContext context) {
    final AdminProvider admin = AdminScope.of(context);
    final List<AdminEvent> log = admin.log;
    final TextTheme text = Theme.of(context).textTheme;

    String hhmmss(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';

    return _Section(
      title: 'Audit log (this run only)',
      icon: Icons.receipt_long_outlined,
      trailing: TextButton(
        onPressed: log.isEmpty ? null : admin.clearLog,
        child: const Text('Clear'),
      ),
      children: <Widget>[
        if (log.isEmpty) const Text('No events yet.'),
        for (final AdminEvent e in log.take(50))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 70,
                  child: Text(hhmmss(e.at), style: text.bodySmall),
                ),
                Expanded(
                  child: Text(
                    e.detail.isEmpty ? e.title : '${e.title} — ${e.detail}',
                    style: text.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
