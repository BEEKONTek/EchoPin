import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// What kind of network the device is on, for the Wi-Fi transport and the
/// "join the same Wi-Fi" hint. Bluetooth state comes from the BLE transport.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService({Connectivity? connectivity, bool enabled = true})
    : _connectivity = enabled ? (connectivity ?? Connectivity()) : null;

  /// A service that always reports "unknown" (tests, unsupported platforms).
  ConnectivityService.disabled() : _connectivity = null;

  final Connectivity? _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Set<ConnectivityResult> _current = <ConnectivityResult>{};
  bool _known = false;

  /// False until the first answer from the OS (and forever if disabled).
  bool get known => _known;

  Set<ConnectivityResult> get current =>
      Set<ConnectivityResult>.unmodifiable(_current);

  /// On a network where peers can be found by Bonjour: Wi-Fi or Ethernet.
  /// Unknown counts as "maybe" so the app never nags without evidence.
  bool get onLocalNetwork =>
      !_known ||
      _current.contains(ConnectivityResult.wifi) ||
      _current.contains(ConnectivityResult.ethernet);

  Future<void> start() async {
    final Connectivity? c = _connectivity;
    if (c == null || _sub != null) return;
    try {
      _update(await c.checkConnectivity().timeout(const Duration(seconds: 3)));
    } catch (_) {
      // Leave as unknown; the stream may still deliver.
    }
    try {
      _sub = c.onConnectivityChanged.listen(_update, onError: (Object _) {});
    } catch (_) {}
  }

  void _update(List<ConnectivityResult> results) {
    final Set<ConnectivityResult> next = results.toSet();
    if (_known && setEquals(next, _current)) return;
    _current = next;
    _known = true;
    notifyListeners();
  }

  @visibleForTesting
  void debugSet(Set<ConnectivityResult> results) => _update(results.toList());

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
