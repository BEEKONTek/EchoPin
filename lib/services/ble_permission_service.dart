import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Requests platform-specific BLE permissions. Injectable for tests.
class BlePermissionService {
  BlePermissionService({Future<bool> Function()? request})
      : _request = request ?? _platformRequest;

  final Future<bool> Function() _request;

  Future<bool> request() => _request();

  static Future<bool> _platformRequest() async {
    if (Platform.isAndroid) {
      final Map<Permission, PermissionStatus> results = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ].request();
      return results.values.every((PermissionStatus s) => s.isGranted);
    }
    if (Platform.isIOS) return true;
    return false;
  }
}
