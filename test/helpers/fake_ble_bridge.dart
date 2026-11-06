import 'dart:async';

import 'package:echo_pin/models/session.dart';
import 'package:echo_pin/services/platform_ble_bridge.dart';
import 'package:flutter/foundation.dart';

/// Scriptable stand-in for the native BLE plugin.
class FakeBleBridge implements PlatformBleBridge {
  FakeBleBridge({this.state = BleAdapterState.on, this.startResult = true});

  BleAdapterState state;
  bool startResult;
  bool enableRequested = false;
  int startCalls = 0;
  int stopCalls = 0;
  final List<({Uint8List data, Set<String> to, bool announce})> sent =
      <({Uint8List data, Set<String> to, bool announce})>[];

  final StreamController<BlePeerEvent> _sightings =
      StreamController<BlePeerEvent>.broadcast();
  final StreamController<Uint8List> _frames =
      StreamController<Uint8List>.broadcast();
  final StreamController<BleAdapterState> _adapter =
      StreamController<BleAdapterState>.broadcast();

  bool get startCalled => startCalls > 0;

  void emitSighting(String peerId, double distance, {DateTime? at}) {
    _sightings.add(
      BlePeerEvent(
        peerId: peerId,
        displayName: 'Peer $peerId',
        distanceMeters: distance,
        rssi: -60,
        lastSeen: at ?? DateTime.now(),
      ),
    );
  }

  void emitFrame(Uint8List data) => _frames.add(data);

  void setAdapter(BleAdapterState s) {
    state = s;
    _adapter.add(s);
  }

  @override
  Stream<BlePeerEvent> get peerEvents => _sightings.stream;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Stream<BleAdapterState> get adapterStates => _adapter.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<BleAdapterState> adapterState() async => state;

  @override
  Future<bool> requestEnable() async {
    enableRequested = true;
    return true;
  }

  @override
  Future<bool> start({
    required String sessionId,
    required String peerId,
    required String displayName,
  }) async {
    startCalls++;
    return startResult;
  }

  @override
  Future<int> send(
    Uint8List data, {
    Set<String> to = const <String>{},
    bool announce = false,
  }) async {
    sent.add((data: data, to: to, announce: announce));
    return to.isEmpty ? 1 : to.length;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> injectPeer(PeerPresence peer) async {}

  @override
  Future<void> dispose() async {
    await _sightings.close();
    await _frames.close();
    await _adapter.close();
  }
}
