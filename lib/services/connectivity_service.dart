import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:echo_pin/services/network_interfaces.dart';
import 'package:flutter/foundation.dart';

/// Interface addresses by interface name (see [listInterfaceAddresses]).
typedef InterfaceLister = Future<Map<String, List<String>>> Function();

/// Which local networks [addressesByName] are on, judged by interface name
/// and address: `wl*` is Wi-Fi, `en*`/`eth*` is Ethernet, and only a real
/// IPv4 address counts (not loopback or self-assigned 169.254.x.x). Docker
/// bridges and VPN tunnels are ignored: nearby phones are not behind them.
Set<ConnectivityResult> linksFromInterfaces(
  Map<String, List<String>> addressesByName,
) {
  final Set<ConnectivityResult> out = <ConnectivityResult>{};
  for (final MapEntry<String, List<String>> e in addressesByName.entries) {
    if (!e.value.any(_isLanIpv4)) continue;
    final String name = e.key;
    if (name.startsWith('wl')) {
      out.add(ConnectivityResult.wifi);
    } else if (name.startsWith('en') || name.startsWith('eth')) {
      out.add(ConnectivityResult.ethernet);
    }
  }
  return out;
}

bool _isLanIpv4(String address) {
  final List<String> parts = address.split('.');
  if (parts.length != 4 || parts.any((String p) => int.tryParse(p) == null)) {
    return false;
  }
  return !address.startsWith('127.') && !address.startsWith('169.254.');
}

bool _isLan(Set<ConnectivityResult> r) =>
    r.contains(ConnectivityResult.wifi) ||
    r.contains(ConnectivityResult.ethernet);

/// What kind of network the device is on, for the Wi-Fi transport and the
/// "join the same Wi-Fi" hint. Bluetooth state comes from the BLE transport.
///
/// On Linux connectivity_plus only asks NetworkManager, so Wi-Fi run by iwd,
/// systemd-networkd or ConnMan reads as "none". There the interfaces are
/// checked as well ([interfaces]), and re-checked every [recheckEvery]
/// because NetworkManager will not announce changes it does not manage.
class ConnectivityService extends ChangeNotifier {
  ConnectivityService({
    Connectivity? connectivity,
    bool enabled = true,
    InterfaceLister? interfaces,
    this.recheckEvery = const Duration(seconds: 15),
  }) : _connectivity = enabled ? (connectivity ?? Connectivity()) : null,
       _interfaces = !enabled
           ? null
           : interfaces ?? (_linuxDesktop ? listInterfaceAddresses : null);

  /// A service that always reports "unknown" (tests, unsupported platforms).
  ConnectivityService.disabled()
    : _connectivity = null,
      _interfaces = null,
      recheckEvery = Duration.zero;

  static bool get _linuxDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  final Connectivity? _connectivity;
  final InterfaceLister? _interfaces;
  final Duration recheckEvery;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _recheck;
  List<ConnectivityResult> _lastFromOs = const <ConnectivityResult>[];
  Set<ConnectivityResult> _current = <ConnectivityResult>{};
  bool _known = false;
  bool _disposed = false;

  /// False until the first answer from the OS (and forever if disabled).
  bool get known => _known;

  Set<ConnectivityResult> get current =>
      Set<ConnectivityResult>.unmodifiable(_current);

  /// On a network where peers can be found by Bonjour: Wi-Fi or Ethernet.
  /// Unknown counts as "maybe" so the app never nags without evidence.
  bool get onLocalNetwork => !_known || _isLan(_current);

  Future<void> start() async {
    final Connectivity? c = _connectivity;
    if (c == null || _sub != null) return;
    try {
      await _refresh(
        await c.checkConnectivity().timeout(const Duration(seconds: 3)),
      );
    } catch (_) {
      // Leave as unknown; the stream may still deliver.
    }
    try {
      _sub = c.onConnectivityChanged.listen(
        (List<ConnectivityResult> r) => unawaited(_refresh(r)),
        onError: (Object _) {},
      );
    } catch (_) {} // best effort: no connectivity channel on this platform
    if (_interfaces != null && recheckEvery > Duration.zero) {
      _recheck = Timer.periodic(
        recheckEvery,
        (_) => unawaited(_refresh(_lastFromOs)),
      );
    }
  }

  Future<void> _refresh(List<ConnectivityResult> fromOs) async {
    _lastFromOs = fromOs;
    Set<ConnectivityResult> next = fromOs.toSet();
    final InterfaceLister? list = _interfaces;
    if (list != null && !_isLan(next)) {
      try {
        final Set<ConnectivityResult> seen = linksFromInterfaces(await list());
        if (seen.isNotEmpty) {
          next = <ConnectivityResult>{
            ...next.where(
              (ConnectivityResult r) => r != ConnectivityResult.none,
            ),
            ...seen,
          };
        }
      } catch (_) {
        // Keep the OS answer.
      }
    }
    _apply(next);
  }

  void _apply(Set<ConnectivityResult> next) {
    if (_disposed) return;
    if (_known && setEquals(next, _current)) return;
    _current = next;
    _known = true;
    notifyListeners();
  }

  @visibleForTesting
  void debugSet(Set<ConnectivityResult> results) => _apply(results);

  @override
  void dispose() {
    _disposed = true;
    _recheck?.cancel();
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
