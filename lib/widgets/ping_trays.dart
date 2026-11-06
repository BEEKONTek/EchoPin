import 'package:echo_pin/models/ping.dart';
import 'package:echo_pin/ui/format.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:flutter/material.dart';

/// A ping someone sent to this device, with one-tap answers.
class IncomingPingTray extends StatelessWidget {
  const IncomingPingTray({
    super.key,
    required this.ping,
    required this.onRespond,
    required this.onDismiss,
    this.distance,
  });

  final IncomingPing ping;
  final ValueChanged<PingResponse> onRespond;
  final VoidCallback onDismiss;

  /// How far the sender is, if a radio can tell.
  final String? distance;

  @override
  Widget build(BuildContext context) {
    final bool sos = ping.kind == PingKind.sos;
    final Color color = sos ? EchoTheme.sos : EchoTheme.checkIn;
    // On someone else's SOS the only useful answer is "On my way"; the
    // automatic receipt already tells them this device saw it.
    final List<PingResponse> answers = sos
        ? const <PingResponse>[PingResponse.coming]
        : const <PingResponse>[
            PingResponse.ok,
            PingResponse.coming,
            PingResponse.help,
          ];

    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        color: sos ? EchoTheme.sos : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(EchoTheme.radius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    sos ? Icons.sos : Icons.waving_hand_outlined,
                    color: sos ? Colors.white : color,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      sos
                          ? '${ping.fromName} needs help'
                          : '${ping.fromName} is checking in',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: sos ? Colors.white : null,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.close,
                      size: 18,
                      color: sos ? Colors.white : null,
                    ),
                    onPressed: onDismiss,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 34, right: 8),
                child: Text(
                  <String>[
                    if (ping.note != null) '“${ping.note}”',
                    if (distance != null) 'About $distance away',
                    Fmt.ago(ping.receivedAt),
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 13,
                    color: sos
                        ? Colors.white.withValues(alpha: 0.9)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: <Widget>[
                    for (int i = 0; i < answers.length; i++)
                      i == 0
                          ? FilledButton(
                              key: Key('ping.answer.${answers[i].wire}'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 40),
                                backgroundColor: sos ? Colors.white : color,
                                foregroundColor: sos
                                    ? EchoTheme.sos
                                    : Colors.white,
                              ),
                              onPressed: () => onRespond(answers[i]),
                              child: Text(answers[i].label),
                            )
                          : OutlinedButton(
                              key: Key('ping.answer.${answers[i].wire}'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 40),
                                foregroundColor: sos ? Colors.white : null,
                                side: BorderSide(
                                  color: sos
                                      ? Colors.white.withValues(alpha: 0.7)
                                      : color.withValues(alpha: 0.6),
                                ),
                              ),
                              onPressed: () => onRespond(answers[i]),
                              child: Text(answers[i].label),
                            ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A ping this device sent: who has it, who answered.
class OutgoingPingTray extends StatelessWidget {
  const OutgoingPingTray({
    super.key,
    required this.ping,
    required this.onClose,
  });

  final OutgoingPing ping;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool sos = ping.kind == PingKind.sos;
    final int total = ping.recipients.length;
    final int answered = ping.count(DeliveryState.answered);
    final int delivered = ping.count(DeliveryState.delivered);
    final int lost = ping.count(DeliveryState.unreachable);
    final int sending = ping.count(DeliveryState.sending);
    final bool needsHelp = ping.recipients.values.any(
      (RecipientStatus r) => r.response == PingResponse.help,
    );

    final String summary = <String>[
      '$answered of $total answered',
      if (delivered > 0) '$delivered delivered',
      if (sending > 0) '$sending sending',
      if (lost > 0) '$lost no answer',
    ].join(' · ');

    return Material(
      color: sos
          ? EchoTheme.sos.withValues(alpha: 0.12)
          : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(EchoTheme.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  sos ? Icons.sos : Icons.near_me_outlined,
                  color: sos ? EchoTheme.sos : scheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    sos
                        ? 'Your SOS is live'
                        : ping.broadcast
                        ? 'Check-in with everyone'
                        : 'Check-in',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  key: Key('ping.close.${ping.id}'),
                  onPressed: onClose,
                  child: Text(sos ? "I'm safe" : 'Clear'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 30, right: 8),
              child: Text(
                summary,
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (needsHelp)
              Padding(
                padding: const EdgeInsets.only(left: 30, top: 4),
                child: Text(
                  'Someone answered “Need help”.',
                  style: TextStyle(
                    color: EchoTheme.sos,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final RecipientStatus r in ping.recipients.values)
                    _RecipientChip(status: r),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipientChip extends StatelessWidget {
  const _RecipientChip({required this.status});
  final RecipientStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color) = switch (status.state) {
      DeliveryState.sending => (Icons.schedule, scheme.onSurfaceVariant),
      DeliveryState.delivered => (Icons.done, scheme.primary),
      DeliveryState.unreachable => (Icons.portable_wifi_off, scheme.error),
      DeliveryState.answered => switch (status.response) {
        PingResponse.help => (Icons.priority_high, EchoTheme.sos),
        PingResponse.coming => (Icons.directions_walk, scheme.primary),
        _ => (Icons.done_all, Colors.green.shade600),
      },
    };
    return AnimatedContainer(
      duration: EchoTheme.medium,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            status.response != null
                ? '${status.name}: ${status.response!.label}'
                : status.name,
            style: TextStyle(fontSize: 12, color: color),
          ),
        ],
      ),
    );
  }
}
