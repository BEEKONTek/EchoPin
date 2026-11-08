// TRANSPORT INTERFACE: what every radio looks like to the session engine.
//
// Bluetooth LE, Wi-Fi/LAN and the in-memory loopback all implement
// MessageTransport: start, stop, send bytes to a peer or everyone, and a
// stream of received bytes. They carry only already-encrypted envelopes;
// security lives in the engine, not in any radio. TransportStatus reports
// health (running / waiting for a radio / unsupported / failed) for the
// status trays.

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/models/peer_link.dart';
import 'package:flutter/foundation.dart';

export 'package:echo_pin/models/peer_link.dart';

enum TransportHealth {
  /// Not started.
  idle,

  /// Running and able to send.
  running,

  /// Started, but its radio is off / unauthorised. Recovers by itself when
  /// the radio comes back.
  waiting,

  /// Not available on this platform or build.
  unsupported,

  /// Crashed; see [TransportStatus.problem].
  failed,
}

@immutable
class TransportStatus {
  const TransportStatus(this.health, {this.problem, this.reachable = 0});

  static const TransportStatus idle = TransportStatus(TransportHealth.idle);

  final TransportHealth health;
  final EchoError? problem;

  /// Peers currently reachable through this transport.
  final int reachable;

  bool get isUp => health == TransportHealth.running;

  @override
  bool operator ==(Object other) =>
      other is TransportStatus &&
      other.health == health &&
      other.problem?.message == problem?.message &&
      other.reachable == reachable;

  @override
  int get hashCode => Object.hash(health, problem?.message, reachable);
}

/// Opaque encrypted frame received from the radio.
@immutable
class TransportFrame {
  const TransportFrame(this.bytes, this.link);
  final Uint8List bytes;
  final PeerLink link;
}

/// Delivery hint. Transports cannot read frames (they are encrypted), so the
/// engine tells them how much effort a frame deserves.
enum SendUrgency {
  /// Periodic hello. BLE skips peers it announced to recently.
  announce,

  /// Normal message.
  normal,

  /// Pings and replies: deliver now, never skip.
  urgent,
}

/// A radio that moves opaque frames between session members.
///
/// Implementations never throw from [send]; failures surface through
/// [status]. All crypto happens above this layer, so transports only see
/// public routing ids and ciphertext.
abstract class MessageTransport {
  PeerLink get link;
  String get label;

  TransportStatus get status;
  Stream<TransportStatus> get statusChanges;
  Stream<TransportFrame> get frames;

  /// Peer ids currently reachable through this transport.
  Set<String> get reachablePeers;

  /// Starts discovery + listening. Returns false only when the transport can
  /// never work here (unsupported). Radio-off is a `waiting` status instead.
  Future<bool> start({required String sessionId, required String peerId});

  /// Sends [frame] to [to] (empty = every reachable peer). Returns how many
  /// peers it was handed to.
  Future<int> send(
    Uint8List frame, {
    Set<String> to = const <String>{},
    SendUrgency urgency = SendUrgency.normal,
  });

  Future<void> stop();
}
