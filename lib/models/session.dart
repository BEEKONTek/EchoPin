class PeerPresence {
  const PeerPresence({
    required this.id,
    required this.label,
    required this.bearingDegrees,
    required this.distanceMeters,
    this.lastSeen,
  });

  final String id;
  final String label;
  final double bearingDegrees;
  final double distanceMeters;
  final DateTime? lastSeen;

  PeerPresence copyWith({
    String? id,
    String? label,
    double? bearingDegrees,
    double? distanceMeters,
    DateTime? lastSeen,
  }) {
    return PeerPresence(
      id: id ?? this.id,
      label: label ?? this.label,
      bearingDegrees: bearingDegrees ?? this.bearingDegrees,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

class Session {
  Session({
    required this.id,
    required this.name,
    this.boundaryRadiusMeters = 150,
    List<PeerPresence>? peers,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       peers = peers ?? <PeerPresence>[];

  final String id;
  final String name;
  final DateTime createdAt;
  final double boundaryRadiusMeters;
  final List<PeerPresence> peers;

  Session copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    double? boundaryRadiusMeters,
    List<PeerPresence>? peers,
  }) {
    return Session(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      boundaryRadiusMeters: boundaryRadiusMeters ?? this.boundaryRadiusMeters,
      peers: peers ?? this.peers,
    );
  }
}
