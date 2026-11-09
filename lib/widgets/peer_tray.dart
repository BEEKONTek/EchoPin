import 'package:echo_pin/models/peer_link.dart';
import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/ui/format.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:flutter/material.dart';

/// How long without any sign of life before a peer shows as "away".
const Duration peerAwayAfter = Duration(seconds: 60);

/// One person in the session, as a tray.
class PeerTray extends StatelessWidget {
  const PeerTray({
    super.key,
    required this.peer,
    required this.boundaryRadius,
    required this.now,
    this.selectionMode = false,
    this.selected = false,
    this.pingState,
    this.needsHelp = false,
    this.onTap,
    this.onLongPress,
  });

  final PeerPresence peer;
  final double boundaryRadius;
  final DateTime now;
  final bool selectionMode;
  final bool selected;

  /// This peer's status in the most recent ping sent to them, if any.
  final RecipientStatus? pingState;

  /// This peer has a live SOS. Outranks [pingState].
  final bool needsHelp;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  bool get _away {
    final DateTime? seen = peer.lastSeen;
    return seen != null && now.difference(seen) > peerAwayAfter;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool inside =
        peer.hasDistance && peer.distanceMeters <= boundaryRadius;
    final Color accent = !peer.authenticated || _away
        ? scheme.outline
        : !peer.hasDistance
        ? scheme.tertiary
        : inside
        ? scheme.primary
        : scheme.error;

    return Semantics(
      selected: selected,
      label: '${peer.label}, ${_subtitle()}',
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(EchoTheme.radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: <Widget>[
                _Avatar(
                  label: peer.label,
                  color: accent,
                  dimmed: !peer.authenticated || _away,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              peer.label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: peer.authenticated
                                    ? scheme.onSurface
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (peer.verified) ...<Widget>[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.verified,
                              size: 16,
                              color: scheme.primary,
                              semanticLabel: 'verified',
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: EchoTheme.fast,
                  transitionBuilder: (Widget c, Animation<double> a) =>
                      ScaleTransition(scale: a, child: c),
                  child: selectionMode
                      ? Icon(
                          selected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          key: ValueKey<bool>(selected),
                          color: selected ? scheme.primary : scheme.outline,
                        )
                      : _Trailing(
                          key: ValueKey<String>(
                            '$needsHelp-${pingState?.state}-'
                            '${pingState?.response}-$inside',
                          ),
                          peer: peer,
                          inside: inside,
                          ping: pingState,
                          needsHelp: needsHelp,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle() {
    if (!peer.authenticated) return 'Unconfirmed signal · not verified yet';
    final List<String> parts = <String>[];
    if (peer.hasDistance) {
      parts.add(Fmt.distance(peer.distanceMeters));
      // BLE gives no direction; only simulated/test peers have a real one.
      if (peer.hasBearing) parts.add('${peer.bearingDegrees.round()}°');
    } else {
      parts.add('Distance unknown');
    }
    final List<String> via = <String>[
      if (peer.links.contains(PeerLink.ble)) 'Bluetooth',
      if (peer.links.contains(PeerLink.lan)) 'Wi-Fi',
      if (peer.links.contains(PeerLink.loopback)) 'Demo',
      if (peer.links.contains(PeerLink.synthetic)) 'Synthetic',
    ];
    if (via.isNotEmpty) parts.add(via.join(' + '));
    final DateTime? seen = peer.lastSeen;
    if (_away && seen != null) parts.add('seen ${Fmt.ago(seen, now)}');
    return parts.join(' · ');
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.label,
    required this.color,
    required this.dimmed,
  });

  final String label;
  final Color color;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: EchoTheme.medium,
      curve: EchoTheme.enter,
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: dimmed ? 0.10 : 0.16),
        border: Border.all(color: color, width: 2),
      ),
      alignment: Alignment.center,
      child: Text(
        Fmt.initials(label),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
      ),
    );
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({
    super.key,
    required this.peer,
    required this.inside,
    required this.ping,
    required this.needsHelp,
  });

  final PeerPresence peer;
  final bool inside;
  final RecipientStatus? ping;
  final bool needsHelp;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final RecipientStatus? p = ping;
    // Their live SOS beats any answer they gave to an earlier ping.
    final (String, Color)? chip = needsHelp
        ? ('SOS', EchoTheme.sos)
        : p == null
        ? null
        : switch (p.state) {
            DeliveryState.sending => ('Pinging…', scheme.onSurfaceVariant),
            DeliveryState.delivered => ('Delivered', scheme.primary),
            DeliveryState.unreachable => ('No answer', scheme.error),
            DeliveryState.answered => switch (p.response) {
              PingResponse.help => ('Needs help', EchoTheme.sos),
              PingResponse.coming => ('On the way', scheme.primary),
              _ => ("OK", Colors.green.shade600),
            },
          };
    if (chip != null) {
      final (String text, Color color) = chip;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      );
    }
    if (!peer.authenticated || !peer.hasDistance) {
      return const SizedBox(width: 24);
    }
    return Icon(
      inside ? Icons.check_circle : Icons.warning_amber_rounded,
      color: inside ? Colors.green.shade600 : scheme.error,
      semanticLabel: inside ? 'inside boundary' : 'outside boundary',
    );
  }
}
