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
