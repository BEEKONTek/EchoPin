import 'dart:async';

import 'package:echo_pin/core/echo_error.dart';
import 'package:echo_pin/services/ble_permission_service.dart';
import 'package:echo_pin/services/session_codec.dart';
import 'package:echo_pin/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Whether this platform has an in-app QR scanner.
bool get qrScanSupported {
  if (kIsWeb) return true;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// Scans an EchoPin invite QR and pops with the raw payload (a code or an
/// `echopin://join` link). Other QR codes are rejected in place with a
/// precise message instead of closing the scanner.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, this.codec});

  final SessionCodec? codec;

  static Future<String?> open(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QrScanScreen()),
    );
  }

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  late final SessionCodec _codec = widget.codec ?? SessionCodec();
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
  );
  String? _problem;
  bool _done = false;
  Timer? _clear;

  @override
  void dispose() {
    _clear?.cancel();
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final Barcode b in capture.barcodes) {
      final String? raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        _codec.parse(raw);
      } on InvalidCodeError catch (e) {
        _showProblem(e.message);
        continue;
      }
      _done = true;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(raw);
      return;
    }
  }

  void _showProblem(String message) {
    setState(() => _problem = message);
    _clear?.cancel();
    _clear = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _problem = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan invite'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => unawaited(_controller.toggleTorch()),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder:
                (BuildContext context, MobileScannerException error) =>
                    _ScannerError(error: error),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: AnimatedSwitcher(
              duration: EchoTheme.fast,
              child: _problem == null
                  ? const Text(
                      'Point at the QR code on the host’s screen',
                      key: ValueKey<String>('hint'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    )
                  : Container(
                      key: ValueKey<String>(_problem!),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        _problem!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error});
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final bool denied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    final bool unsupported =
        error.errorCode == MobileScannerErrorCode.unsupported;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                denied ? Icons.no_photography_outlined : Icons.videocam_off,
                color: Colors.white,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                denied
                    ? const PermissionDeniedError(PermissionKind.camera).message
                    : unsupported
                    ? 'This device has no usable camera. Paste the code instead.'
                    : 'The camera could not start. Paste the code instead.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
              const SizedBox(height: 20),
              if (denied)
                FilledButton(
                  onPressed: () =>
                      unawaited(BlePermissionService.openSettings()),
                  child: const Text('Open Settings'),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Back',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
