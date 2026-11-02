import 'dart:collection';
import 'dart:convert';

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

  factory MeshMessage.fromJson(String peerId, String jsonBody) {
    final decoded = jsonDecode(jsonBody);
    final payload = decoded['payload'] as Map<String, dynamic>? ?? const {};
    return MeshMessage(
      fromPeerId: peerId,
      type: decoded['type'] as String? ?? 'presence',
      payload: payload,
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
  MeshService({this.maxPeers = 20});

  final int maxPeers;
  final Map<String, int> _lastNonceByPeer = {};
  final Map<String, DateTime> _lastSeenByPeer = {};
  final Map<String, int> _tokenBuckets = {};
  final SplayTreeMap<String, DateTime> _lastMessageAt = SplayTreeMap();

  bool canAcceptPeer(String peerId) => _lastSeenByPeer.length < maxPeers || _lastSeenByPeer.containsKey(peerId);

  bool onRawMessageReceived({
    required String fromPeerId,
    required String jsonMessage,
    required Map<String, SessionPeer> peers,
  }) {
    if (!canAcceptPeer(fromPeerId)) {
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

      final bucket = _tokenBuckets[fromPeerId] ?? 5;
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
    for (final entry in _lastMessageAt.entries) {
      final peerId = entry.key;
      final last = entry.value;
      if (now.difference(last).inMilliseconds >= 500) {
        final current = _tokenBuckets[peerId] ?? 5;
        _tokenBuckets[peerId] = current >= 5 ? 5 : current + 1;
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
