import 'dart:async';

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/transport/message_transport.dart';
import 'package:flutter/foundation.dart';

/// Browsers cannot open raw sockets or browse mDNS, so on the web this
/// transport is permanently `unsupported`.
class LanTransport implements MessageTransport {
  LanTransport({String serviceType = '_echopin._tcp'});

  static const bool isSupported = false;

  final StreamController<TransportStatus> _status =
      StreamController<TransportStatus>.broadcast();

  @override
  PeerLink get link => PeerLink.lan;

  @override
  String get label => 'Wi-Fi';

  @override
  TransportStatus get status => const TransportStatus(
    TransportHealth.unsupported,
    problem: TransportError('Wi-Fi', 'not available in the browser'),
  );

  @override
  Stream<TransportStatus> get statusChanges => _status.stream;

  @override
  Stream<TransportFrame> get frames => const Stream<TransportFrame>.empty();

  @override
  Set<String> get reachablePeers => const <String>{};

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
  }) async => false;

  @override
  Future<int> send(
    Uint8List frame, {
    Set<String> to = const <String>{},
    SendUrgency urgency = SendUrgency.normal,
  }) async => 0;

  @override
  Future<void> stop() => _status.close();
}
