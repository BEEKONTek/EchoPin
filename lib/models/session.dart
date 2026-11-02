class SessionPeer {
  const SessionPeer({
    required this.peerId,
    required this.displayName,
    required this.emoji,
    this.relativeBearingDeg = 0,
    this.relativeDistanceM = 0,
    this.outsideBoundary = false,
    this.lastSeen,
  });

  final String peerId;
  final String displayName;
  final String emoji;
  final double relativeBearingDeg;
  final double relativeDistanceM;
  final bool outsideBoundary;
  final DateTime? lastSeen;

  bool get isStale =>
      lastSeen != null &&
      DateTime.now().difference(lastSeen!).inSeconds > 10;

  SessionPeer copyWith({
    String? peerId,
    String? displayName,
    String? emoji,
    double? relativeBearingDeg,
    double? relativeDistanceM,
    bool? outsideBoundary,
    DateTime? lastSeen,
  }) {
    return SessionPeer(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      emoji: emoji ?? this.emoji,
      relativeBearingDeg: relativeBearingDeg ?? this.relativeBearingDeg,
      relativeDistanceM: relativeDistanceM ?? this.relativeDistanceM,
      outsideBoundary: outsideBoundary ?? this.outsideBoundary,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

enum SessionStatus { inactive, joining, active, expired }

class EchoSession {
  EchoSession({
    required this.sessionId,
    required this.qrPayload,
    required this.createdAt,
    required this.expiresAt,
    required this.boundaryRadiusM,
    this.status = SessionStatus.joining,
    Map<String, SessionPeer>? peers,
    this.ownPeerId = 'local-peer',
  }) : peers = Map<String, SessionPeer>.from(peers ?? const {});

  final String sessionId;
  final String qrPayload;
  final DateTime createdAt;
  final DateTime expiresAt;
  final double boundaryRadiusM;
  final SessionStatus status;
  final Map<String, SessionPeer> peers;
  final String ownPeerId;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get isActive => status == SessionStatus.active && !isExpired;

  List<SessionPeer> get activePeers => peers.values
      .where((peer) => !peer.isStale)
      .toList()
    ..sort((a, b) => a.relativeDistanceM.compareTo(b.relativeDistanceM));

  bool get anyPeerOutsideBoundary => activePeers.any((peer) => peer.outsideBoundary);

  static String generateSessionCode() {
    const charset = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    final buffer = StringBuffer();
    for (var i = 0; i < 6; i++) {
      final codePoint = (random + i * 131) % charset.length;
      buffer.write(charset[codePoint]);
    }
    return buffer.toString();
  }

  static EchoSession create({
    String? sessionId,
    double boundaryRadiusM = 200,
    Duration sessionDuration = const Duration(hours: 8),
    String ownPeerId = 'local-peer',
    Object? peers,
  }) {
    final now = DateTime.now();
    final code = sessionId ?? generateSessionCode();
    final payload =
        'echopin://join?s=$code&exp=${now.add(sessionDuration).millisecondsSinceEpoch}';

    final normalizedPeers = <String, SessionPeer>{};
    if (peers is Map<String, SessionPeer>) {
      normalizedPeers.addAll(peers);
    } else if (peers is List<SessionPeer>) {
      for (final peer in peers) {
        normalizedPeers[peer.peerId] = peer;
      }
    }

    return EchoSession(
      sessionId: code,
      qrPayload: payload,
      createdAt: now,
      expiresAt: now.add(sessionDuration),
      boundaryRadiusM: boundaryRadiusM,
      status: SessionStatus.active,
      peers: normalizedPeers,
      ownPeerId: ownPeerId,
    );
  }

  EchoSession updatePeer(SessionPeer updatedPeer) {
    final next = Map<String, SessionPeer>.from(peers)
      ..[updatedPeer.peerId] = updatedPeer.copyWith(
        outsideBoundary: updatedPeer.relativeDistanceM > boundaryRadiusM,
        lastSeen: DateTime.now(),
      );

    return EchoSession(
      sessionId: sessionId,
      qrPayload: qrPayload,
      createdAt: createdAt,
      expiresAt: expiresAt,
      boundaryRadiusM: boundaryRadiusM,
      status: status,
      peers: next,
      ownPeerId: ownPeerId,
    );
  }

  EchoSession removePeer(String peerId) {
    final next = Map<String, SessionPeer>.from(peers)..remove(peerId);
    return EchoSession(
      sessionId: sessionId,
      qrPayload: qrPayload,
      createdAt: createdAt,
      expiresAt: expiresAt,
      boundaryRadiusM: boundaryRadiusM,
      status: status,
      peers: next,
      ownPeerId: ownPeerId,
    );
  }

  EchoSession wipe() {
    return EchoSession(
      sessionId: sessionId,
      qrPayload: qrPayload,
      createdAt: createdAt,
      expiresAt: expiresAt,
      boundaryRadiusM: boundaryRadiusM,
      status: SessionStatus.inactive,
      peers: const {},
      ownPeerId: ownPeerId,
    );
  }
}
