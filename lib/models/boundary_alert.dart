import 'package:flutter/foundation.dart';

enum CrossingDirection { entered, exited }

/// A single peer boundary crossing event.
///
/// Aligned with the existing [PeerPresence] shape (`peerId` + `peerLabel` +
/// `distanceMeters`) so callers can map without translation.
@immutable
class BoundaryAlert {
  const BoundaryAlert({
    required this.id,
    required this.peerId,
    required this.peerLabel,
    required this.direction,
    required this.distanceMeters,
    required this.at,
  });

  final String id;
  final String peerId;
  final String peerLabel;
  final CrossingDirection direction;
  final double distanceMeters;
  final DateTime at;

  String get message {
    final String action = direction == CrossingDirection.entered
        ? 'entered'
        : 'left';
    return '$peerLabel $action the boundary '
        '(${distanceMeters.toStringAsFixed(1)} m)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BoundaryAlert && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
