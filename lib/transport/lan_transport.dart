/// Wi-Fi / hotspot transport: Bonjour (mDNS) discovery + framed TCP.
///
/// Native-only (`dart:io`); on the web the stub reports `unsupported`.
library;

export 'lan_transport_stub.dart' if (dart.library.io) 'lan_transport_io.dart';
