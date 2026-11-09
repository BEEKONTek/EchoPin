import 'package:echo_pin/models/peer_link.dart';

/// One person as this device sees them: who (authenticated identity) and
/// where (relative distance/bearing, when a radio can measure it).
class PeerPresence {
  const PeerPresence({
    required this.id,
    required this.label,
    required this.bearingDegrees,
    required this.distanceMeters,
    this.lastSeen,
    this.authenticated = true,
    this.hasDistance = true,
    this.hasBearing = true,
    this.links = const <PeerLink>{},
    this.safetyCode,
    this.verified = false,
  });

  final String id;
  final String label;
  final double bearingDegrees;
  final double distanceMeters;
  final DateTime? lastSeen;

  /// A signed message from this peer has been verified. False for raw BLE
  /// sightings that have not introduced themselves yet: those are shown as
  /// "unconfirmed" and never trigger boundary alerts.
  final bool authenticated;

  /// False when the peer is reachable (e.g. over Wi-Fi) but no radio can
  /// estimate their distance. Such peers are listed but not drawn.
  final bool hasDistance;

  /// False when [bearingDegrees] was not measured. Bluetooth signal
  /// strength gives a distance but no direction, so a Bluetooth sighting's
  /// angle is only a stable placeholder for laying out the radar. Only the
  /// demo crowd and admin test peers carry a real (simulated) direction.
  final bool hasBearing;

  final Set<PeerLink> links;

  /// 12-digit code to compare in person; null until authenticated.
  final String? safetyCode;

  /// The person on this device confirmed the safety code in person.
  final bool verified;

  PeerPresence copyWith({
    String? id,
    String? label,
    double? bearingDegrees,
    double? distanceMeters,
    DateTime? lastSeen,
    bool? authenticated,
    bool? hasDistance,
    bool? hasBearing,
    Set<PeerLink>? links,
    String? safetyCode,
    bool? verified,
  }) {
    return PeerPresence(
      id: id ?? this.id,
      label: label ?? this.label,
      bearingDegrees: bearingDegrees ?? this.bearingDegrees,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      lastSeen: lastSeen ?? this.lastSeen,
      authenticated: authenticated ?? this.authenticated,
      hasDistance: hasDistance ?? this.hasDistance,
      hasBearing: hasBearing ?? this.hasBearing,
      links: links ?? this.links,
      safetyCode: safetyCode ?? this.safetyCode,
      verified: verified ?? this.verified,
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
    this.code,
    this.expiresAt,
    this.demo = false,
  }) : createdAt = createdAt ?? DateTime.now(),
       peers = peers ?? <PeerPresence>[];

  /// Public routing id (safe to show; derived one-way from the code).
  final String id;
  final String name;
  final DateTime createdAt;
  final double boundaryRadiusMeters;
  final List<PeerPresence> peers;

  /// The shareable invite code. Secret: whoever has it can join.
  final String? code;

  /// Sessions end automatically after 8 hours.
  final DateTime? expiresAt;

  /// Simulated people (demo mode), not real radios.
  final bool demo;

  Session copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    double? boundaryRadiusMeters,
    List<PeerPresence>? peers,
    String? code,
    DateTime? expiresAt,
    bool? demo,
  }) {
    return Session(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      boundaryRadiusMeters: boundaryRadiusMeters ?? this.boundaryRadiusMeters,
      peers: peers ?? this.peers,
      code: code ?? this.code,
      expiresAt: expiresAt ?? this.expiresAt,
      demo: demo ?? this.demo,
    );
  }
}
