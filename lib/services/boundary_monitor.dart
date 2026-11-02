import 'package:echo_pin/models/boundary_alert.dart';
import 'package:echo_pin/models/session.dart';

/// Pure function: given two snapshots of the peer list, return the crossing
/// events that occurred between them.
///
/// Rules:
///   - Only fires for peers that exist in **both** snapshots. New peers do not
///     trigger an alert on first appearance (no "previous" state).
///   - Exactly-on-radius counts as inside (consistent with the UI check in
///     session_screen.dart).
///   - No filtering of "self" — the caller decides whether self is present in
///     the peer list. The current [PeerPresence] model has no isSelf marker.
List<BoundaryAlert> computeCrossings({
  required List<PeerPresence> previous,
  required List<PeerPresence> current,
  required double boundaryRadiusMeters,
  required DateTime now,
}) {
  final Map<String, PeerPresence> byId = <String, PeerPresence>{
    for (final PeerPresence p in previous) p.id: p,
  };

  final List<BoundaryAlert> out = <BoundaryAlert>[];
  for (final PeerPresence peer in current) {
    final PeerPresence? prev = byId[peer.id];
    if (prev == null) continue;

    final bool prevInside = prev.distanceMeters <= boundaryRadiusMeters;
    final bool nowInside = peer.distanceMeters <= boundaryRadiusMeters;
    if (prevInside == nowInside) continue;

    out.add(
      BoundaryAlert(
        id: '${peer.id}-${now.microsecondsSinceEpoch}',
        peerId: peer.id,
        peerLabel: peer.label,
        direction: nowInside
            ? CrossingDirection.entered
            : CrossingDirection.exited,
        distanceMeters: peer.distanceMeters,
        at: now,
      ),
    );
  }
  return out;
}
