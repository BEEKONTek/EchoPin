// Lists this machine's network addresses (for diagnostics and Wi-Fi
// checks). Native platforms only; the web build uses the _stub version,
// chosen by the conditional import in network_interfaces.dart.

import 'dart:io';

Future<Map<String, List<String>>> listInterfaceAddresses() async {
  final List<NetworkInterface> list = await NetworkInterface.list(
    includeLinkLocal: true,
  );
  return <String, List<String>>{
    for (final NetworkInterface i in list)
      i.name: <String>[for (final InternetAddress a in i.addresses) a.address],
  };
}
