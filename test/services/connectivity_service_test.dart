import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:echo_pin/services/connectivity_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// What connectivity_plus reports on Linux when NetworkManager does not
/// manage the Wi-Fi (iwd, systemd-networkd, ConnMan).
class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this.results);
  final List<ConnectivityResult> results;
  final StreamController<List<ConnectivityResult>> _changes =
      StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => results;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;
}

void main() {
  group('linksFromInterfaces', () {
    final List<(String, Map<String, List<String>>, Set<ConnectivityResult>)>
    cases = <(String, Map<String, List<String>>, Set<ConnectivityResult>)>[
      (
        'Wi-Fi on a phone hotspot',
        <String, List<String>>{
          'wlan0': <String>['172.20.10.9'],
        },
        <ConnectivityResult>{ConnectivityResult.wifi},
      ),
      (
        'predictable Wi-Fi name',
        <String, List<String>>{
          'wlp2s0': <String>['192.168.1.20'],
        },
        <ConnectivityResult>{ConnectivityResult.wifi},
      ),
      (
        'wired Ethernet',
        <String, List<String>>{
          'enp3s0': <String>['10.0.0.4'],
          'eth1': <String>['10.0.1.4'],
        },
        <ConnectivityResult>{ConnectivityResult.ethernet},
      ),
      (
        'Docker bridge, VPN and loopback do not reach nearby phones',
        <String, List<String>>{
          'docker0': <String>['172.17.0.1'],
          'tailscale0': <String>['100.64.0.7'],
          'lo': <String>['127.0.0.1'],
        },
        <ConnectivityResult>{},
      ),
      (
        'Wi-Fi with only a self-assigned address is not connected',
        <String, List<String>>{
          'wlan0': <String>['169.254.10.3', 'fe80::1'],
        },
        <ConnectivityResult>{},
      ),
    ];
    for (final (
          String name,
          Map<String, List<String>> ifs,
          Set<ConnectivityResult> want,
        )
        in cases) {
      test(name, () => expect(linksFromInterfaces(ifs), want));
    }
  });

  group('when the OS reports no network', () {
    test('Wi-Fi it cannot see still counts as a local network', () async {
      final ConnectivityService s = ConnectivityService(
        connectivity: _FakeConnectivity(<ConnectivityResult>[
          ConnectivityResult.none,
        ]),
        interfaces: () async => <String, List<String>>{
          'wlan0': <String>['172.20.10.9'],
        },
      );
      addTearDown(s.dispose);
      await s.start();
      expect(s.onLocalNetwork, isTrue);
      expect(s.current, contains(ConnectivityResult.wifi));
    });

    test('and no interface is on a LAN, it really is offline', () async {
      final ConnectivityService s = ConnectivityService(
        connectivity: _FakeConnectivity(<ConnectivityResult>[
          ConnectivityResult.none,
        ]),
        interfaces: () async => <String, List<String>>{
          'docker0': <String>['172.17.0.1'],
        },
      );
      addTearDown(s.dispose);
      await s.start();
      expect(s.known, isTrue);
      expect(s.onLocalNetwork, isFalse);
    });
  });
}
