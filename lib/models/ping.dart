import 'package:flutter/foundation.dart';

enum PingKind {
  /// "Are you OK?" to selected people or everyone.
  checkIn('checkin'),

  /// "I'm lost / need help" to everyone. Retried for longer, louder alerts.
  sos('sos');

  const PingKind(this.wire);
  final String wire;

  static PingKind? fromWire(Object? v) {
    for (final PingKind k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

enum PingResponse {
  ok('ok', "I'm OK"),
  coming('coming', 'On my way'),
  help('help', 'Need help');

  const PingResponse(this.wire, this.label);
  final String wire;
  final String label;

  static PingResponse? fromWire(Object? v) {
    for (final PingResponse r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }
}

enum DeliveryState {
  /// Being retried; no receipt yet.
  sending,

  /// Recipient's device confirmed receipt.
  delivered,

  /// Recipient answered.
  answered,

  /// Gave up after the retry budget.
  unreachable,
}

@immutable
class RecipientStatus {
  const RecipientStatus({
    required this.peerId,
    required this.name,
    this.state = DeliveryState.sending,
    this.response,
    this.updatedAt,
    this.attempts = 0,
  });

  final String peerId;
  final String name;
  final DeliveryState state;
  final PingResponse? response;
  final DateTime? updatedAt;
  final int attempts;

  RecipientStatus copyWith({
    DeliveryState? state,
    PingResponse? response,
    DateTime? updatedAt,
    int? attempts,
  }) {
    return RecipientStatus(
      peerId: peerId,
      name: name,
      state: state ?? this.state,
      response: response ?? this.response,
      updatedAt: updatedAt ?? this.updatedAt,
      attempts: attempts ?? this.attempts,
    );
  }
}

/// A ping this device sent.
@immutable
class OutgoingPing {
  const OutgoingPing({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.recipients,
    this.note,
    this.broadcast = false,
    this.cancelled = false,
  });

  final String id;
  final PingKind kind;
  final DateTime createdAt;
  final Map<String, RecipientStatus> recipients;
  final String? note;

  /// Sent to everyone (recipients = members at send time).
  final bool broadcast;
  final bool cancelled;

  /// Check-ins finish when everyone answered or gave up; an SOS stays live
  /// until its sender says they are safe (it also reaches late joiners).
  bool get finished =>
      cancelled ||
      (kind != PingKind.sos &&
          recipients.isNotEmpty &&
          recipients.values.every(
            (RecipientStatus r) =>
                r.state == DeliveryState.answered ||
                r.state == DeliveryState.unreachable,
          ));

  int count(DeliveryState s) =>
      recipients.values.where((RecipientStatus r) => r.state == s).length;

  OutgoingPing copyWith({
    Map<String, RecipientStatus>? recipients,
    bool? cancelled,
  }) {
    return OutgoingPing(
      id: id,
      kind: kind,
      createdAt: createdAt,
      recipients: recipients ?? this.recipients,
      note: note,
      broadcast: broadcast,
      cancelled: cancelled ?? this.cancelled,
    );
  }
}

/// A ping someone sent to this device.
@immutable
class IncomingPing {
  const IncomingPing({
    required this.id,
    required this.kind,
    required this.fromId,
    required this.fromName,
    required this.receivedAt,
    this.note,
    this.response,
    this.dismissed = false,
    this.resolved = false,
  });

  final String id;
  final PingKind kind;
  final String fromId;
  final String fromName;
  final DateTime receivedAt;
  final String? note;
  final PingResponse? response;
  final bool dismissed;

  /// The sender ended it (an SOS whose sender is now safe).
  final bool resolved;

  /// Still shown as an alert. Answering closes a check-in, but not an SOS:
  /// the sender needs help until they say they are safe.
  bool get open {
    if (dismissed || resolved) return false;
    return kind == PingKind.sos || response == null;
  }

  IncomingPing copyWith({
    PingResponse? response,
    bool? dismissed,
    bool? resolved,
  }) {
    return IncomingPing(
      id: id,
      kind: kind,
      fromId: fromId,
      fromName: fromName,
      receivedAt: receivedAt,
      note: note,
      response: response ?? this.response,
      dismissed: dismissed ?? this.dismissed,
      resolved: resolved ?? this.resolved,
    );
  }
}
