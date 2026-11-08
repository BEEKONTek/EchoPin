/// This device's network interface addresses, by interface name.
///
/// Native-only (`dart:io`); on the web the stub reports none.
library;

export 'network_interfaces_stub.dart'
    if (dart.library.io) 'network_interfaces_io.dart';
