import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum PermissionOutcome { granted, denied, permanentlyDenied, notApplicable }

/// Requests platform-specific BLE permissions. Injectable for tests.
///
/// Uses [defaultTargetPlatform] rather than `dart:io` so the file compiles
/// for the web.
class BlePermissionService {
  BlePermissionService({
    Future<bool> Function()? request,
    Future<PermissionOutcome> Function()? requestDetailed,
  }) : _requestDetailed =
           requestDetailed ??
           (request == null
               ? _platformRequest
               : () async => await request()
                     ? PermissionOutcome.granted
                     : PermissionOutcome.denied);

  static const MethodChannel _ble = MethodChannel('echo_pin/ble/methods');

  final Future<PermissionOutcome> Function() _requestDetailed;
  PermissionOutcome? _last;

  /// The most recent outcome, so the UI can offer "Open Settings" once the
  /// OS stops showing the prompt.
  PermissionOutcome? get lastOutcome => _last;

  Future<bool> request() async {
    final PermissionOutcome o = await requestDetailed();
    return o == PermissionOutcome.granted ||
        o == PermissionOutcome.notApplicable;
  }

  Future<PermissionOutcome> requestDetailed() async {
    try {
      _last = await _requestDetailed();
    } catch (_) {
      _last = PermissionOutcome.denied;
    }
    return _last!;
  }

  /// Opens this app's page in system settings.
  static Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }

  static Future<PermissionOutcome> _platformRequest() async {
    if (kIsWeb) return PermissionOutcome.denied;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        // Android 12+ (API 31) has dedicated Bluetooth permissions declared
        // `neverForLocation`. Older versions require fine location to scan.
        final int sdk = await _androidSdkInt();
        final List<Permission> needed = sdk >= 31
            ? <Permission>[
                Permission.bluetoothScan,
                Permission.bluetoothAdvertise,
                Permission.bluetoothConnect,
              ]
            : <Permission>[Permission.locationWhenInUse];
        final Map<Permission, PermissionStatus> results = await needed
            .request();
        if (results.values.every((PermissionStatus s) => s.isGranted)) {
          return PermissionOutcome.granted;
        }
        if (results.values.any((PermissionStatus s) => s.isPermanentlyDenied)) {
          return PermissionOutcome.permanentlyDenied;
        }
        return PermissionOutcome.denied;
      case TargetPlatform.iOS:
        // CoreBluetooth presents its own prompt on first use; denial is
        // reported through the adapter state as `unauthorized`.
        return PermissionOutcome.notApplicable;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return PermissionOutcome.denied;
    }
  }

  static Future<int> _androidSdkInt() async {
    try {
      return await _ble.invokeMethod<int>('sdkInt') ?? 31;
    } catch (_) {
      return 31;
    }
  }
}
