package com.example.echo_pin

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.pow

class BleBridgePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var context: Context? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private var sessionId: String = ""
    private var peerId: String = ""

    companion object {
        private const val METHOD_CHANNEL = "echo_pin/ble/methods"
        private const val EVENT_CHANNEL = "echo_pin/ble/events"
        private const val MANUFACTURER_ID = 0x0E0C
        private const val NOMINAL_TX_POWER = -59.0
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
            .also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
            .also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ping" -> result.success(true)
            "start" -> {
                sessionId = call.argument<String>("sessionId") ?: ""
                peerId = call.argument<String>("peerId") ?: ""
                result.success(start())
            }
            "stop" -> { stop(); result.success(null) }
            "inject" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    @SuppressLint("MissingPermission")
    private fun start(): Boolean {
        val ctx = context ?: return false
        if (sessionId.length != 8 || peerId.length != 8) return false
        if (!hasPermissions()) return false
        val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: return false
        val adapter = manager.adapter ?: return false
        if (!adapter.isEnabled) return false

        try {
            advertiser = adapter.bluetoothLeAdvertiser
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(false)
                .build()
            val payload = (sessionId + peerId).toByteArray(Charsets.UTF_8)
            val data = AdvertiseData.Builder()
                .addManufacturerData(MANUFACTURER_ID, payload)
                .setIncludeDeviceName(false)
                .build()
            advertiseCallback = object : AdvertiseCallback() {
                override fun onStartSuccess(s: AdvertiseSettings) {}
                override fun onStartFailure(code: Int) {
                    eventSink?.error("advertise_failure", "code=$code", null)
                }
            }
            advertiser?.startAdvertising(settings, data, advertiseCallback)
        } catch (e: Exception) {
            eventSink?.error("advertise_exception", e.message, null)
        }

        try {
            scanner = adapter.bluetoothLeScanner
            scanCallback = object : ScanCallback() {
                override fun onScanResult(type: Int, result: ScanResult) {
                    handleScanResult(result)
                }
                override fun onBatchScanResults(results: MutableList<ScanResult>) {
                    results.forEach { handleScanResult(it) }
                }
                override fun onScanFailed(code: Int) {
                    eventSink?.error("scan_failure", "code=$code", null)
                }
            }
            val scanSettings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()
            scanner?.startScan(emptyList(), scanSettings, scanCallback)
        } catch (e: Exception) {
            eventSink?.error("scan_exception", e.message, null)
        }
        return true
    }

    private fun handleScanResult(result: ScanResult) {
        val record = result.scanRecord ?: return
        val data = record.getManufacturerSpecificData(MANUFACTURER_ID) ?: return
        if (data.size < 16) return
        val text = String(data, Charsets.UTF_8)
        if (text.length < 16) return
        if (text.substring(0, 8) != sessionId) return
        val remotePeer = text.substring(8, 16)
        if (remotePeer == peerId) return
        val rssi = result.rssi
        val distance = 10.0.pow((NOMINAL_TX_POWER - rssi) / 20.0)
        eventSink?.success(mapOf(
            "peerId" to remotePeer,
            "displayName" to "Peer $remotePeer",
            "distanceMeters" to distance,
            "rssi" to rssi,
            "lastSeenMs" to System.currentTimeMillis(),
        ))
    }

    @SuppressLint("MissingPermission")
    private fun stop() {
        try { advertiseCallback?.let { advertiser?.stopAdvertising(it) } }
        catch (_: Exception) {}
        try { scanCallback?.let { scanner?.stopScan(it) } }
        catch (_: Exception) {}
        advertiseCallback = null
        scanCallback = null
        advertiser = null
        scanner = null
    }

    private fun hasPermissions(): Boolean {
        val ctx = context ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    override fun onCancel(arguments: Any?) { eventSink = null }
}
