import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:echo_pin/services/key_value_store.dart';

/// This install's Ed25519 device key, kept in the OS keystore.
///
/// The private half never leaves the device. Signing in registers the
/// public half with the server, and every token refresh is signed with it,
/// so a copied refresh token is worthless anywhere else. This replaces any
/// idea of identifying phones by IMEI or serial number: those are public,
/// copyable numbers, and many platforms no longer expose them at all.
class DeviceKeyStore {
  DeviceKeyStore(this._kv);

  final KeyValueStore _kv;
  static const String _kKey = 'echo_pin.device_key_v1';
  SimpleKeyPair? _cached;

  Future<SimpleKeyPair> keyPair() async {
    final SimpleKeyPair? c = _cached;
    if (c != null) return c;
    final String? stored = await _kv.read(_kKey);
    List<int>? seed;
    if (stored != null) {
      try {
        seed = base64.decode(stored);
        if (seed.length != 32) seed = null;
      } catch (_) {
        seed = null;
      }
    }
    if (seed == null) {
      final Random r = Random.secure();
      seed = List<int>.generate(32, (_) => r.nextInt(256));
      await _kv.write(_kKey, base64.encode(seed));
    }
    return _cached = await Ed25519().newKeyPairFromSeed(seed);
  }

  Future<List<int>> publicKey() async =>
      (await (await keyPair()).extractPublicKey()).bytes;

  /// Replaces the key, e.g. after this device was removed from the account
  /// (the server refuses the old key forever).
  Future<void> rotate() async {
    _cached = null;
    await _kv.delete(_kKey);
  }
}
