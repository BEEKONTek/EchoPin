// Web stand-in for network_interfaces_io.dart: browsers can't list network
// interfaces, so this reports none.

Future<Map<String, List<String>>> listInterfaceAddresses() async =>
    const <String, List<String>>{};
