class SessionPeer {
  SessionPeer({
    required this.peerId,
    required this.displayName,
    required this.emoji,
    required this.relativeBearingDeg,
    required this.relativeDistanceM,
    required this.outsideBoundary,
    required this.lastSeen,
    this.batteryLow = false,
  });

  final String peerId;
  final String displayName;
  final String emoji;
  final double relativeBearingDeg;
  final double relativeDistanceM;
  final bool outsideBoundary;
  final DateTime lastSeen;
  final bool batteryLow;

  bool get isStale => DateTime.now().difference(lastSeen).inSeconds > 10;

  SessionPeer copyWith({
    String? peerId,
    String? displayName,
    String? emoji,
    double? relativeBearingDeg,
    double? relativeDistanceM,
    bool? outsideBoundary,
    DateTime? lastSeen,
    bool? batteryLow,
  }) {
    return SessionPeer(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      emoji: emoji ?? this.emoji,
      relativeBearingDeg: relativeBearingDeg ?? this.relativeBearingDeg,
      relativeDistanceM: relativeDistanceM ?? this.relativeDistanceM,
      outsideBoundary: outsideBoundary ?? this.outsideBoundary,
      lastSeen: lastSeen ?? this.lastSeen,
      batteryLow: batteryLow ?? this.batteryLow,
    );
  }
}

class SessionKeys {
  SessionKeys({
    required this.identityPrivateKey,
    required this.identityPublicKey,
    required this.ephemeralPrivateKey,
    required this.ephemeralPublicKey,
    required this.sessionSeed,
  });

  final String identityPrivateKey;
  final String identityPublicKey;
  final String ephemeralPrivateKey;
  final String ephemeralPublicKey;
  final List<int> sessionSeed;
}

class EchoSession {
  EchoSession({
    required this.sessionId,
    required this.boundaryRadiusM,
    required this.ownPeerId,
    required this.status,
    required this.keys,
    required this.createdAt,
    this.expiresAt,
    this.peers = const <SessionPeer>[],
    this.qrPayload,
  });

  final String sessionId;
  final double boundaryRadiusM;
  final String ownPeerId;
  final String status;
  final SessionKeys keys;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final List<SessionPeer> peers;
  final String? qrPayload;

  bool get isExpired {
    if (expiresAt == null) {
      return false;
    }
    return DateTime.now().isAfter(expiresAt!);
  }

  List<SessionPeer> get activePeers => peers
      .where((peer) => !peer.isStale)
      .toList()
    ..sort((a, b) => a.relativeDistanceM.compareTo(b.relativeDistanceM));

  void wipe() {
    // placeholder for clearing in-memory session data
  }

  EchoSession copyWith({
    String? sessionId,
    double? boundaryRadiusM,
    String? ownPeerId,
    String? status,
    SessionKeys? keys,
    DateTime? createdAt,
    DateTime? expiresAt,
    List<SessionPeer>? peers,
    String? qrPayload,
  }) {
    return EchoSession(
      sessionId: sessionId ?? this.sessionId,
      boundaryRadiusM: boundaryRadiusM ?? this.boundaryRadiusM,
      ownPeerId: ownPeerId ?? this.ownPeerId,
      status: status ?? this.status,
      keys: keys ?? this.keys,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      peers: peers ?? this.peers,
      qrPayload: qrPayload ?? this.qrPayload,
    );
  }
}

String createSessionCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = DateTime.now().millisecondsSinceEpoch;
  final buffer = StringBuffer();
  for (var i = 0; i < 6; i++) {
    buffer.write(chars[(random + i) % chars.length]);
  }
  return buffer.toString();
}

String createSessionId() => createSessionCode();

SessionKeys createSessionKeys() {
  return SessionKeys(
    identityPrivateKey: 'identity_private_key',
    identityPublicKey: 'identity_public_key',
    ephemeralPrivateKey: 'ephemeral_private_key',
    ephemeralPublicKey: 'ephemeral_public_key',
    sessionSeed: List<int>.generate(32, (index) => index + 1),
  );
}
