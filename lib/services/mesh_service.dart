import 'dart:convert';
import 'dart:math' as math;

import '../models/session.dart';

class MeshMessage {
  const MeshMessage({
    required this.fromPeerId,
    required this.type,
    required this.payload,
    required this.nonce,
    required this.timestamp,
  });

  final String fromPeerId;
  final String type;
  final Map<String, dynamic> payload;
  final int nonce;
  final DateTime timestamp;

  factory MeshMessage.fromJson(String peerId, String jsonText) {
    final decoded = jsonDecode(jsonText) as Map<String, dynamic>;
    return MeshMessage(
      fromPeerId: peerId,
      type: decoded['type'] as String? ?? 'presence',
      payload: Map<String, dynamic>.from(decoded['payload'] as Map? ?? {}),
      nonce: decoded['nonce'] as int? ?? 0,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        decoded['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'fromPeerId': fromPeerId,
        'type': type,
        'payload': payload,
        'nonce': nonce,
        'timestamp': timestamp.millisecondsSinceEpoch,
      };
}

class MeshService {
  MeshService({this.maxPeers = 20, this.maxTokensPerPeer = 5});

  final int maxPeers;
  final int maxTokensPerPeer;

  final Map<String, int> _lastNonceByPeer = <String, int>{};
  final Map<String, DateTime> _lastSeenByPeer = <String, DateTime>{};
  final Map<String, int> _tokenBuckets = <String, int>{};
  final Map<String, DateTime> _lastMessageAt = <String, DateTime>{};

  bool canAcceptPeer(String peerId) {
    return _lastSeenByPeer.length < maxPeers || _lastSeenByPeer.containsKey(peerId);
  }

  bool onRawMessageReceived({
    required String fromPeerId,
    required String jsonMessage,
    required Map<String, SessionPeer> peers,
  }) {
    if (!canAcceptPeer(fromPeerId) && !peers.containsKey(fromPeerId)) {
      return false;
    }

    try {
      final message = MeshMessage.fromJson(fromPeerId, jsonMessage);
      final now = DateTime.now();
      final previousNonce = _lastNonceByPeer[fromPeerId];

      if (previousNonce != null && message.nonce <= previousNonce) {
        return false;
      }

      final lastSeen = _lastSeenByPeer[fromPeerId];
      if (lastSeen != null && now.difference(lastSeen).inSeconds > 30) {
        _lastNonceByPeer.remove(fromPeerId);
      }

      final bucket = _tokenBuckets[fromPeerId] ?? maxTokensPerPeer;
      if (bucket <= 0) {
        return false;
      }

      _tokenBuckets[fromPeerId] = bucket - 1;
      _lastNonceByPeer[fromPeerId] = message.nonce;
      _lastSeenByPeer[fromPeerId] = now;
      _lastMessageAt[fromPeerId] = now;
      return true;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    }
  }

  void refillTokens() {
    final now = DateTime.now();
    for (final peerId in _lastMessageAt.keys) {
      final lastMessageAt = _lastMessageAt[peerId]!;
      if (now.difference(lastMessageAt).inMilliseconds >= 500) {
        final current = _tokenBuckets[peerId] ?? maxTokensPerPeer;
        _tokenBuckets[peerId] = math.min(maxTokensPerPeer, current + 1);
      }
    }
  }

  void removePeer(String peerId) {
    _lastNonceByPeer.remove(peerId);
    _lastSeenByPeer.remove(peerId);
    _tokenBuckets.remove(peerId);
    _lastMessageAt.remove(peerId);
  }
}
