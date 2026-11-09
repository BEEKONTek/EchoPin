// SESSION SCREEN: the live view while you are in a session.
//
// Layout: an app bar (session name, radio status, menu), the pinwheel of
// people around you, and a draggable sheet listing everyone with their
// status. From here you check in on selected people or everyone, hold the
// SOS button, answer incoming pings, verify someone's safety code in
// person, open the invite (QR + code) and leave.
//
// All state comes from SessionProvider via SessionScope; this file only
// draws it and turns taps into provider calls. A 1-second timer refreshes
// "seen 5 s ago" style labels without touching the provider.

import 'dart:async';

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/app_settings.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/models/status_tray.dart';
import 'package:echo_pin/providers/session_provider.dart';
import 'package:echo_pin/providers/session_scope.dart';
import 'package:echo_pin/screens/admin/admin_gate_screen.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:echo_pin/ui/format.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:echo_pin/widgets/animated_tray_list.dart';
import 'package:echo_pin/widgets/boundary_alert_banner.dart';
import 'package:echo_pin/widgets/peer_tray.dart';
import 'package:echo_pin/widgets/ping_trays.dart';
import 'package:echo_pin/widgets/pinwheel_painter.dart';
import 'package:echo_pin/widgets/sos_button.dart';
import 'package:echo_pin/widgets/status_tray_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

enum _MenuItem { safety, admin, leave }

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final Set<String> _selected = <String>{};
  final DraggableScrollableController _sheet = DraggableScrollableController();
  Timer? _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Drives "seen 2 min ago", away states and the expiry countdown.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sheet.dispose();
    super.dispose();
  }

  bool get _selecting => _selected.isNotEmpty;

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Actions ────────────────────────────────────────────────────────────

  Future<void> _confirmLeave() async {
    final SessionProvider provider = SessionScope.read(context);
    final bool demo = provider.session?.demo ?? false;
    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(demo ? 'End the demo?' : 'Leave this session?'),
        content: Text(
          demo
              ? 'The simulated people will disappear.'
              : 'People will see that you left. You can rejoin from '
                    'Recent sessions while it lasts.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            key: const Key('session.leave.confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(demo ? 'End demo' : 'Leave'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    final NavigatorState nav = Navigator.of(context);
    await provider.leaveSession();
    nav.popUntil((Route<dynamic> r) => r.isFirst);
  }

  void _toggle(PeerPresence peer) {
    if (!peer.authenticated) {
      _snack('Unconfirmed signals cannot be pinged until they identify');
      return;
    }
    setState(() {
      if (!_selected.remove(peer.id)) _selected.add(peer.id);
    });
  }

  Future<void> _checkIn(SessionProvider provider) async {
    final Set<String>? to = _selecting ? Set<String>.of(_selected) : null;
    try {
      await provider.sendPing(PingKind.checkIn, to: to);
      if (!mounted) return;
      setState(_selected.clear);
      _snack(
        to == null
            ? 'Checking in with everyone'
            : 'Checking in with ${to.length} '
                  '${to.length == 1 ? 'person' : 'people'}',
      );
    } on EchoError catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _sos(SessionProvider provider) async {
    try {
      final OutgoingPing ping = await provider.sendPing(PingKind.sos);
      if (!mounted) return;
      _snack(
        ping.recipients.isEmpty
            ? 'SOS is live. It will reach people as soon as they are in range.'
            : 'SOS sent to everyone. Keep EchoPin open.',
      );
    } on EchoError catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _respond(
    SessionProvider provider,
    IncomingPing ping,
    PingResponse response,
  ) async {
    try {
      await provider.respondToPing(ping, response);
      if (mounted) _snack('Sent “${response.label}” to ${ping.fromName}');
    } on EchoError catch (e) {
      _snack(e.message);
    }
  }

  void _openPeer(PeerPresence peer) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _PeerDetails(peerId: peer.id),
      ),
    );
  }

  void _openInvite() {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const _InviteSheet(),
      ),
    );
  }

  void _openSafety() {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const _SafetySheet(),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final SessionProvider provider = SessionScope.of(context);
    final Session? session = provider.session;
    if (session == null) return _EndedView(reason: provider.endedReason);

    _selected.retainWhere(
      (String id) => session.peers.any((PeerPresence p) => p.id == id),
    );
    final bool wide = MediaQuery.sizeOf(context).width >= 840;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        if (_selecting) {
          setState(_selected.clear);
        } else {
          unawaited(_confirmLeave());
        }
      },
      child: Scaffold(
        appBar: _appBar(provider, session),
        body: SafeArea(
          bottom: false,
          child: wide
              ? Row(
                  children: <Widget>[
                    Expanded(child: _stage(provider, session)),
                    SizedBox(
                      width: 420,
                      child: _SheetSurface(
                        side: true,
                        child: CustomScrollView(
                          slivers: _slivers(provider, session, sheet: false),
                        ),
                      ),
                    ),
                  ],
                )
              : LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    return Stack(
                      children: <Widget>[
                        Positioned.fill(
                          child: _stage(
                            provider,
                            session,
                            reserve: c.maxHeight * 0.36,
                          ),
                        ),
                        DraggableScrollableSheet(
                          controller: _sheet,
                          initialChildSize: 0.4,
                          minChildSize: 0.2,
                          maxChildSize: 0.92,
                          snap: true,
                          snapSizes: const <double>[0.4],
                          builder:
                              (BuildContext context, ScrollController scroll) {
                                return _SheetSurface(
                                  child: CustomScrollView(
                                    controller: scroll,
                                    slivers: _slivers(
                                      provider,
                                      session,
                                      sheet: true,
                                    ),
                                  ),
                                );
                              },
                        ),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar(SessionProvider provider, Session session) {
    return AppBar(
      titleSpacing: 16,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(session.name, overflow: TextOverflow.ellipsis),
          _RadioStrip(provider: provider, demo: session.demo),
        ],
      ),
      actions: <Widget>[
        IconButton(
          key: const Key('session.invite'),
          tooltip: 'Invite',
          icon: const Icon(Icons.qr_code_2),
          onPressed: _openInvite,
        ),
        PopupMenuButton<_MenuItem>(
          key: const Key('session.menu'),
          tooltip: 'More',
          onSelected: (_MenuItem item) {
            switch (item) {
              case _MenuItem.safety:
                _openSafety();
              case _MenuItem.admin:
                unawaited(openAdmin(context));
              case _MenuItem.leave:
                unawaited(_confirmLeave());
            }
          },
          itemBuilder: (BuildContext context) => <PopupMenuEntry<_MenuItem>>[
            const PopupMenuItem<_MenuItem>(
              value: _MenuItem.safety,
              child: ListTile(
                leading: Icon(Icons.verified_user_outlined),
                title: Text('Your safety code'),
              ),
            ),
            const PopupMenuItem<_MenuItem>(
              value: _MenuItem.admin,
              child: ListTile(
                leading: Icon(Icons.admin_panel_settings_outlined),
                title: Text('Admin'),
              ),
            ),
            PopupMenuItem<_MenuItem>(
              value: _MenuItem.leave,
              child: ListTile(
                leading: const Icon(Icons.logout),
                title: Text(session.demo ? 'End demo' : 'Leave session'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Alerts and trays on top, the pinwheel filling the rest.
  Widget _stage(
    SessionProvider provider,
    Session session, {
    double reserve = 0,
  }) {
    final Set<String> sos = provider.peersNeedingHelp;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        return Column(
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: c.maxHeight * 0.45),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Column(
                  children: <Widget>[
                    const BoundaryAlertBanner(),
                    AnimatedTrayList<IncomingPing>(
                      items: provider.openPings,
                      keyOf: (IncomingPing p) => '${p.fromId}:${p.id}',
                      itemBuilder: (BuildContext context, IncomingPing p) =>
                          IncomingPingTray(
                            ping: p,
                            distance: _distanceTo(session, p.fromId),
                            onRespond: (PingResponse r) =>
                                unawaited(_respond(provider, p, r)),
                            onDismiss: () => provider.dismissPing(p),
                          ),
                    ),
                    AnimatedTrayList<StatusTray>(
                      items: provider.trays,
                      keyOf: (StatusTray t) => t.id,
                      itemBuilder: (BuildContext context, StatusTray t) =>
                          StatusTrayView(
                            tray: t,
                            onAction: t.action == TrayAction.none
                                ? null
                                : () => unawaited(provider.runTrayAction(t)),
                            onDismiss: () => provider.dismissTray(t.id),
                          ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(8, 4, 8, reserve),
                child: PinwheelView(
                  peers: session.peers,
                  boundaryRadius: session.boundaryRadiusMeters,
                  rangeMeters: AppSettings.maxRadius,
                  minBoundary: AppSettings.minRadius,
                  syntheticIds: provider.meshService.syntheticPeerIds,
                  highlightIds: sos,
                  onBoundaryChanged: provider.updateBoundaryRadius,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String? _distanceTo(Session session, String peerId) {
    for (final PeerPresence p in session.peers) {
      if (p.id == peerId && p.hasDistance) {
        return Fmt.distance(p.distanceMeters);
      }
    }
    return null;
  }

  Map<String, RecipientStatus> _pingStates(SessionProvider provider) {
    final Map<String, RecipientStatus> out = <String, RecipientStatus>{};
    for (final OutgoingPing ping in provider.outgoingPings) {
      if (ping.cancelled) continue;
      if (_now.difference(ping.createdAt) > const Duration(minutes: 10)) {
        continue;
      }
      for (final RecipientStatus r in ping.recipients.values) {
        out.putIfAbsent(r.peerId, () => r);
      }
    }
    return out;
  }

  List<Widget> _slivers(
    SessionProvider provider,
    Session session, {
    required bool sheet,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<PeerPresence> peers = session.peers;
    final int known = peers.where((PeerPresence p) => p.authenticated).length;
    final int inside = peers
        .where(
          (PeerPresence p) =>
              p.authenticated &&
              p.hasDistance &&
              p.distanceMeters <= session.boundaryRadiusMeters,
        )
        .length;
    final Map<String, RecipientStatus> pingStates = _pingStates(provider);
    final Set<String> needHelp = provider.peersNeedingHelp;
    final List<OutgoingPing> outgoing = provider.outgoingPings
        .where(
          (OutgoingPing p) =>
              !p.cancelled &&
              (p.kind == PingKind.sos ||
                  _now.difference(p.createdAt) < const Duration(minutes: 10)),
        )
        .take(3)
        .toList();
    final OutgoingPing? sos = provider.activeSos;
    final DateTime? ends = session.expiresAt;

    return <Widget>[
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (sheet) const _Handle(),
            Padding(
              padding: EdgeInsets.fromLTRB(20, sheet ? 2 : 14, 12, 2),
              child: AnimatedSwitcher(
                duration: EchoTheme.fast,
                child: _selecting
                    ? Row(
                        key: const ValueKey<String>('selecting'),
                        children: <Widget>[
                          Text(
                            '${_selected.length} selected',
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => setState(_selected.clear),
                            child: const Text('Cancel'),
                          ),
                        ],
                      )
                    : Row(
                        key: const ValueKey<String>('people'),
                        children: <Widget>[
                          Text('People', style: theme.textTheme.titleMedium),
                          const SizedBox(width: 8),
                          _Pill(text: '$known'),
                          const Spacer(),
                          if (known > 0)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                '$inside inside boundary',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const Key('session.checkin'),
                      onPressed: () => unawaited(_checkIn(provider)),
                      icon: const Icon(Icons.waving_hand_outlined),
                      label: Text(
                        _selecting
                            ? 'Check in with ${_selected.length}'
                            : 'Check in with everyone',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SosHoldButton(
                    active: sos != null,
                    onConfirmed: () => unawaited(_sos(provider)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.trip_origin,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text('Boundary', style: theme.textTheme.bodyMedium),
                  Expanded(
                    child: Slider(
                      key: const Key('session.boundary'),
                      value: session.boundaryRadiusMeters
                          .clamp(AppSettings.minRadius, AppSettings.maxRadius)
                          .toDouble(),
                      min: AppSettings.minRadius,
                      max: AppSettings.maxRadius,
                      divisions: 18,
                      label: '${session.boundaryRadiusMeters.round()} m',
                      onChanged: provider.updateBoundaryRadius,
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      '${session.boundaryRadiusMeters.round()} m',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      SliverToBoxAdapter(
        child: AnimatedTrayList<OutgoingPing>(
          items: outgoing,
          keyOf: (OutgoingPing p) => p.id,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          itemBuilder: (BuildContext context, OutgoingPing p) =>
              OutgoingPingTray(
                ping: p,
                onClose: () => unawaited(provider.cancelPing(p.id)),
              ),
        ),
      ),
      SliverToBoxAdapter(
        child: AnimatedSwitcher(
          duration: EchoTheme.medium,
          child: peers.isEmpty
              ? _EmptyPeers(demo: session.demo, onInvite: _openInvite)
              : const SizedBox.shrink(),
        ),
      ),
      AnimatedTrayList<PeerPresence>(
        key: const ValueKey<String>('peers'),
        sliver: true,
        items: peers,
        keyOf: (PeerPresence p) => p.id,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        itemBuilder: (BuildContext context, PeerPresence p) => PeerTray(
          key: ValueKey<String>('peer.${p.id}'),
          peer: p,
          boundaryRadius: session.boundaryRadiusMeters,
          now: _now,
          selectionMode: _selecting,
          selected: _selected.contains(p.id),
          pingState: pingStates[p.id],
          needsHelp: needHelp.contains(p.id),
          onTap: () => _selecting ? _toggle(p) : _openPeer(p),
          onLongPress: () => _toggle(p),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            16 + MediaQuery.paddingOf(context).bottom,
          ),
          child: DefaultTextStyle(
            style: theme.textTheme.bodySmall!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (peers.isNotEmpty)
                  const Text(
                    'Tap someone for details and verification. Long-press to '
                    'select people for a check-in.',
                  ),
                if (provider.selfSafetyCode != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text('Your safety code: ${provider.selfSafetyCode}'),
                ],
                if (ends != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    'Ends automatically in '
                    '${Fmt.remaining(ends.difference(_now))}',
                  ),
                ],
                if (session.demo) ...<Widget>[
                  const SizedBox(height: 6),
                  const Text(
                    'Demo: the people are simulated, but every message uses '
                    'the real encrypted protocol.',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

// ── Pieces ───────────────────────────────────────────────────────────────

class _SheetSurface extends StatelessWidget {
  const _SheetSurface({required this.child, this.side = false});
  final Widget child;
  final bool side;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (side) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(left: BorderSide(color: scheme.outlineVariant)),
        ),
        child: child,
      );
    }
    return Material(
      color: scheme.surface,
      elevation: 8,
      shadowColor: Colors.black38,
      surfaceTintColor: Colors.transparent,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outlineVariant,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: EchoTheme.fast,
      transitionBuilder: (Widget c, Animation<double> a) =>
          ScaleTransition(scale: a, child: c),
      child: Container(
        key: ValueKey<String>(text),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: scheme.onPrimaryContainer,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

/// "Bluetooth · Wi-Fi" under the title, coloured by radio health.
class _RadioStrip extends StatelessWidget {
  const _RadioStrip({required this.provider, required this.demo});
  final SessionProvider provider;
  final bool demo;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<Widget> items = <Widget>[];
    for (final MessageTransport t in provider.transports) {
      if (t.status.health == TransportHealth.unsupported) continue;
      final bool up = t.status.isUp;
      final Color color = switch (t.status.health) {
        TransportHealth.running => scheme.primary,
        TransportHealth.failed => scheme.error,
        _ => scheme.tertiary,
      };
      final IconData icon = switch (t.link) {
        PeerLink.ble => up ? Icons.bluetooth : Icons.bluetooth_disabled,
        PeerLink.lan => up ? Icons.wifi : Icons.wifi_off,
        _ => Icons.science_outlined,
      };
      items.add(
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 3),
              Text(
                demo ? 'Demo' : t.label,
                style: TextStyle(fontSize: 12, color: color),
              ),
            ],
          ),
        ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: items);
  }
}

class _EmptyPeers extends StatelessWidget {
  const _EmptyPeers({required this.demo, required this.onInvite});
  final bool demo;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.radar,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            demo ? 'Starting the simulation…' : 'Waiting for people',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            demo
                ? 'Simulated people will appear in a moment.'
                : 'Share the invite so your group can join. People appear '
                      'here as soon as they are in Bluetooth range or on '
                      'the same Wi-Fi.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          if (!demo) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onInvite,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Show invite'),
            ),
          ],
        ],
      ),
    );
  }
}

class _EndedView extends StatelessWidget {
  const _EndedView({this.reason});
  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Session')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.timer_off_outlined, size: 48),
              const SizedBox(height: 12),
              Text(
                reason ?? 'This session has ended.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).popUntil((Route<dynamic> r) => r.isFirst),
                child: const Text('Back to home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Sheets ───────────────────────────────────────────────────────────────

class _PeerDetails extends StatelessWidget {
  const _PeerDetails({required this.peerId});
  final String peerId;

  @override
  Widget build(BuildContext context) {
    final SessionProvider provider = SessionScope.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    PeerPresence? peer;
    for (final PeerPresence p in provider.session?.peers ?? <PeerPresence>[]) {
      if (p.id == peerId) peer = p;
    }
    if (peer == null) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('This person is no longer in range.'),
        ),
      );
    }
    final PeerPresence p = peer;
    final bool synthetic = provider.isSynthetic(p.id);

    Future<void> checkIn() async {
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      final NavigatorState nav = Navigator.of(context);
      try {
        await provider.sendPing(PingKind.checkIn, to: <String>{p.id});
        nav.pop();
        messenger.showSnackBar(
          SnackBar(content: Text('Checking in with ${p.label}')),
        );
      } on EchoError catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(p.label, style: theme.textTheme.headlineSmall),
                ),
                if (p.verified)
                  Chip(
                    avatar: Icon(
                      Icons.verified,
                      size: 16,
                      color: scheme.primary,
                    ),
                    label: const Text('Verified'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              <String>[
                if (p.hasDistance)
                  'About ${Fmt.distance(p.distanceMeters)} away'
                else
                  'Distance unknown',
                if (p.lastSeen != null) 'seen ${Fmt.ago(p.lastSeen!)}',
              ].join(' · '),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (!p.authenticated)
              Text(
                'This device is advertising your session but has not proven '
                'who it is yet. It cannot receive pings or trigger alerts '
                'until it does.',
                style: theme.textTheme.bodyMedium,
              )
            else if (synthetic)
              Text(
                'Synthetic test peer injected from the admin panel.',
                style: theme.textTheme.bodyMedium,
              )
            else ...<Widget>[
              Text('Safety codes', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                'Compare these in person. If ${p.label}’s phone shows the '
                'same two codes, you are talking to the real ${p.label} and '
                'nobody is in the middle.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              _CodeRow(label: '${p.label}’s code', code: p.safetyCode ?? '—'),
              const SizedBox(height: 8),
              _CodeRow(
                label: 'Your code',
                code: provider.selfSafetyCode ?? '—',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('peer.verify'),
                onPressed: () => provider.setVerified(p, !p.verified),
                icon: Icon(p.verified ? Icons.undo : Icons.verified_outlined),
                label: Text(p.verified ? 'Remove verification' : 'Codes match'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('peer.checkin'),
                onPressed: () => unawaited(checkIn()),
                icon: const Icon(Icons.waving_hand_outlined),
                label: Text('Check in with ${p.label}'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CodeRow extends StatelessWidget {
  const _CodeRow({required this.label, required this.code});
  final String label;
  final String code;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          Text(
            code,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 18,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _InviteSheet extends StatelessWidget {
  const _InviteSheet();

  @override
  Widget build(BuildContext context) {
    final SessionProvider provider = SessionScope.of(context);
    final ThemeData theme = Theme.of(context);
    final String? code = provider.sessionCode;
    final String? link = provider.inviteLink;
    if (code == null || link == null) return const SizedBox.shrink();

    Future<void> copy(String text, String what) async {
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      await Clipboard.setData(ClipboardData(text: text));
      messenger.showSnackBar(SnackBar(content: Text('$what copied')));
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Invite to ${provider.session?.name ?? 'session'}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: QrImageView(
                data: link,
                size: 220,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
            const SizedBox(height: 16),
            SelectableText(
              code,
              key: const Key('invite.code'),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: () => unawaited(copy(code, 'Code')),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy code'),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(copy(link, 'Invite link')),
                  icon: const Icon(Icons.link),
                  label: const Text('Copy link'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Anyone with this code can join and see relative distances. '
              'Share it only with your group.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SafetySheet extends StatelessWidget {
  const _SafetySheet();

  @override
  Widget build(BuildContext context) {
    final SessionProvider provider = SessionScope.of(context);
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('Your safety code', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            _CodeRow(
              label: 'This session',
              code: provider.selfSafetyCode ?? '—',
            ),
            const SizedBox(height: 12),
            Text(
              'When someone opens your details, their phone shows this code. '
              'Comparing it in person proves your messages really come from '
              'you. A new code is made for every session.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
