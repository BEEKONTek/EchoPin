package com.example.echo_pin

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.content.Context
import android.bluetooth.*
import android.bluetooth.le.*
import android.os.Build
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

class MainActivity: FlutterActivity() {
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var sessionId = ""
    private var peerId = ""

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "echo_pin/ble/methods")
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "echo_pin/ble/events")
        
        eventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { eventSink = sink }
            override fun onCancel(args: Any?) { eventSink = null }
        })

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "ping" -> result.success(true)
                "start" -> {
                    sessionId = call.argument<String>("sessionId") ?: ""
                    peerId = call.argument<String>("peerId") ?: ""
                    result.success(startBle())
                }
                "stop" -> { stopBle(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun startBle(): Boolean {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) return false
        
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = manager.adapter ?: return false
        if (!adapter.isEnabled) return false

        try {
            advertiser = adapter.bluetoothLeAdvertiser
            val payload = (sessionId + peerId).toByteArray(Charsets.UTF_8)
            val settings = AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).build()
            val data = AdvertiseData.Builder().addManufacturerData(0x0E0C, payload).build()
            advertiser?.startAdvertising(settings, data, null)

            scanner = adapter.bluetoothLeScanner
            val scanCallback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult) {
                    val data = result.scanRecord?.getManufacturerSpecificData(0x0E0C) ?: return
                    if (data.size < 16) return
                    val text = String(data, Charsets.UTF_8)
                    if (text.startsWith(sessionId) && !text.endsWith(peerId)) {
                        val remotePeer = text.substring(8, 16)
                        val rssi = result.rssi
                        val distance = Math.pow(10.0, ((-59.0 - rssi) / 20.0))
                        eventSink?.success(mapOf(
                            "peerId" to remotePeer,
                            "displayName" to "Peer $remotePeer",
                            "distanceMeters" to distance,
                            "rssi" to rssi,
                            "lastSeenMs" to System.currentTimeMillis()
                        ))
                    }
                }
            }
            scanner?.startScan(emptyList(), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
            return true
        } catch (e: Exception) { return false }
    }

    private fun stopBle() {
        try { advertiser?.stopAdvertising(null) } catch (e: Exception) {}
        try { scanner?.stopScan(null) } catch (e: Exception) {}
    }
}
