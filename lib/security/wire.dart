import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Message kinds carried inside the encrypted envelope. The kind is part of
/// the ciphertext, so an eavesdropper cannot tell a ping from a hello.
enum MessageKind {
  /// Announces display name; doubles as a heartbeat.
  hello(1),

  /// Check-in or SOS to selected recipients or everyone.
  ping(2),

  /// Automatic "delivered" for a ping.
  receipt(3),

  /// A person's answer to a ping.
  reply(4),

  /// Graceful leave.
  bye(5);

  const MessageKind(this.code);
  final int code;

  static MessageKind? fromCode(int code) {
    for (final MessageKind k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// A decrypted, signature-verified message.
@immutable
class SecureMessage {
  const SecureMessage({
    required this.kind,
    required this.senderId,
    required this.senderKey,
    required this.counter,
    required this.sentAt,
    required this.recipients,
    required this.body,
  });

  final MessageKind kind;
  final String senderId;
  final List<int> senderKey;
  final int counter;
  final DateTime sentAt;

  /// Empty means everyone in the session.
  final Set<String> recipients;
  final Map<String, Object?> body;

  bool isFor(String peerId) =>
      recipients.isEmpty || recipients.contains(peerId);
}

/// Byte layout constants. See docs/PROTOCOL.md.
abstract final class Wire {
  static const List<int> magic = <int>[0x45, 0x50]; // "EP"
  static const int version = 2;
  static const int headerLength = 12; // magic 2, version 1, flags 1, sid 8
  static const int nonceLength = 24; // XChaCha20
  static const int macLength = 16; // Poly1305
  static const int keyLength = 32; // Ed25519 public key
  static const int signatureLength = 64;
  static const int peerIdLength = 8;
  static const int maxRecipients = 32;
  static const int maxBodyLength = 1024;

  /// Smallest frame that could possibly be valid.
  static const int minFrame =
      headerLength +
      nonceLength +
      macLength +
      1 +
      keyLength +
      8 +
      8 +
      1 +
      2 +
      signatureLength;

  static const int maxFrame =
      headerLength +
      nonceLength +
      macLength +
      1 +
      keyLength +
      8 +
      8 +
      1 +
      maxRecipients * peerIdLength +
      2 +
      maxBodyLength +
      signatureLength;

  static Uint8List header(String sessionId) {
    final List<int> sid = ascii.encode(sessionId);
    if (sid.length != peerIdLength) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must be 8 ASCII');
    }
    return Uint8List.fromList(<int>[...magic, version, 0, ...sid]);
  }
}

/// Big-endian 64-bit integers built from two 32-bit halves, because
/// `ByteData.setUint64` is unsupported when compiled to JavaScript.
void writeU64(BytesBuilder b, int value) {
  final int hi = value ~/ 0x100000000;
  final int lo = value % 0x100000000;
  final ByteData d = ByteData(8)
    ..setUint32(0, hi)
    ..setUint32(4, lo);
  b.add(d.buffer.asUint8List());
}

int readU64(Uint8List bytes, int offset) {
  final ByteData d = ByteData.sublistView(bytes, offset, offset + 8);
  return d.getUint32(0) * 0x100000000 + d.getUint32(4);
}
