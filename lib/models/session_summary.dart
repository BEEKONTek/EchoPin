import 'package:flutter/foundation.dart';

/// Persisted summary of a past session. Mirrors the fields of [Session] that
/// matter for the "recent sessions" list, plus the encoded code so a tap can
/// rejoin directly. No peer data, no locations, only what is needed to
/// identify a session you already belong to.
@immutable
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.name,
    required this.code,
    required this.boundaryRadiusMeters,
    required this.createdAt,
    required this.lastJoinedAt,
  });

  final String id;
  final String name;
  final String code;
  final double boundaryRadiusMeters;
  final DateTime createdAt;
  final DateTime lastJoinedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'code': code,
    'boundaryRadiusMeters': boundaryRadiusMeters,
    'createdAt': createdAt.toIso8601String(),
    'lastJoinedAt': lastJoinedAt.toIso8601String(),
  };

  factory SessionSummary.fromJson(Map<String, dynamic> json) {
    return SessionSummary(
      id: json['id'] as String,
      name: json['name'] as String,
      code: json['code'] as String,
      boundaryRadiusMeters: (json['boundaryRadiusMeters'] as num).toDouble(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastJoinedAt: DateTime.parse(json['lastJoinedAt'] as String),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionSummary &&
          other.id == id &&
          other.name == name &&
          other.code == code &&
          other.boundaryRadiusMeters == boundaryRadiusMeters &&
          other.createdAt == createdAt &&
          other.lastJoinedAt == lastJoinedAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    code,
    boundaryRadiusMeters,
    createdAt,
    lastJoinedAt,
  );
}
