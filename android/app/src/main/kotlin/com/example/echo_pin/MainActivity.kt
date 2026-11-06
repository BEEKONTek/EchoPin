package com.example.echo_pin

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The BLE bridge lives in BleBridgePlugin; register it once here so
        // the method/event channels exist before Dart probes them.
        flutterEngine.plugins.add(BleBridgePlugin())
    }
}
