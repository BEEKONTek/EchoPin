package com.example.echo_pin

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Native half of the BLE transport.
 *
 * Deliberately dumb: it advertises `sessionId || peerId`, scans for the same
 * session (RSSI gives distance), and moves opaque byte frames over GATT.
 * Every frame is already encrypted and signed in Dart, so nothing here
 * handles secrets.
 *
 * Frames are split into chunks `[messageId, index, count, payload...]` that
 * each fit one ATT write, written with response, one peer at a time.
 *
 * All state is touched only on the main thread: Bluetooth callbacks arrive on
 * binder threads and are posted to [main] before doing anything.
 */
class BleBridgePlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        private const val METHOD_CHANNEL = "echo_pin/ble/methods"
        private const val EVENT_CHANNEL = "echo_pin/ble/events"
        private const val MANUFACTURER_ID = 0x0E0C
        private const val NOMINAL_TX_POWER = -59.0

        // iOS cannot advertise manufacturer data, so iOS peers put the same
        // 16-byte payload in the local name, prefixed with this marker.
        private const val LOCAL_NAME_PREFIX = "EP"

        val SERVICE_UUID: UUID = UUID.fromString("6e3f0001-8c2a-4e5b-9d1e-3c7a5b2f0e01")
        val INBOX_UUID: UUID = UUID.fromString("6e3f0002-8c2a-4e5b-9d1e-3c7a5b2f0e01")

        private const val CHUNK_HEADER = 3
        private const val DESIRED_MTU = 247
        private const val JOB_TIMEOUT_MS = 10_000L
        private const val IDLE_CLOSE_MS = 15_000L
        private const val ANNOUNCE_INTERVAL_MS = 60_000L
        private const val PEER_FRESH_MS = 30_000L
        private const val REASSEMBLY_TIMEOUT_MS = 15_000L
        private const val MAX_QUEUE = 64
        private const val REQUEST_ENABLE_BT = 0x4543
    }

    private val main = Handler(Looper.getMainLooper())
    private var context: Context? = null
    private var activity: Activity? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var receiverRegistered = false

    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private var gattServer: BluetoothGattServer? = null
    private var sessionId: String = ""
    private var peerId: String = ""

    // Peers seen in advertisements: peerId -> device.
    private val devices = HashMap<String, BluetoothDevice>()
    private val lastSeen = HashMap<String, Long>()
    private val lastAnnounce = HashMap<String, Long>()

    // Outgoing frames, one GATT conversation at a time.
    private class SendJob(val peerId: String, val data: ByteArray, val messageId: Int)

    private val urgent = ArrayDeque<SendJob>()
    private val announces = ArrayDeque<SendJob>()
    private var activeJob: SendJob? = null
    private var activeTimeout: Runnable? = null
    private var nextMessageId = 0

    private class Link(val gatt: BluetoothGatt) {
        var ready = false
        var mtu = 23
        var inbox: BluetoothGattCharacteristic? = null
        val chunks = ArrayDeque<ByteArray>()
        var closeTask: Runnable? = null
    }

    private val links = HashMap<String, Link>()

    // Incoming chunk reassembly: "deviceAddress:messageId" -> partial frame.
    private class Partial(val count: Int, val startedAt: Long) {
        val parts = arrayOfNulls<ByteArray>(count)
        var received = 0
    }

    private val partials = HashMap<String, Partial>()

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            main.post {
                if (state == BluetoothAdapter.STATE_TURNING_OFF || state == BluetoothAdapter.STATE_OFF) {
                    teardownRadio()
                }
                emitAdapter()
            }
        }
    }

    // ── Flutter plumbing ───────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
            .also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
            .also { it.setStreamHandler(this) }
        registerAdapterReceiver()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        unregisterAdapterReceiver()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
        emitAdapter()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ping" -> result.success(true)
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "adapterState" -> result.success(adapterState())
            "requestEnable" -> result.success(requestEnable())
            "start" -> {
                sessionId = call.argument<String>("sessionId") ?: ""
                peerId = call.argument<String>("peerId") ?: ""
                result.success(start())
            }
            "send" -> {
                val data = call.argument<ByteArray>("data")
                val to = call.argument<List<String>>("to") ?: emptyList()
                val announce = call.argument<Boolean>("announce") ?: false
                result.success(if (data == null) 0 else send(data, to, announce))
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            "inject" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    // ── Adapter state ──────────────────────────────────────────────────────

    private fun registerAdapterReceiver() {
        val ctx = context ?: return
        if (receiverRegistered) return
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                ctx.registerReceiver(adapterReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                ctx.registerReceiver(adapterReceiver, filter)
            }
            receiverRegistered = true
        } catch (_: Exception) {
        }
    }

    private fun unregisterAdapterReceiver() {
        if (!receiverRegistered) return
        try {
            context?.unregisterReceiver(adapterReceiver)
        } catch (_: Exception) {
        }
        receiverRegistered = false
    }

    private fun adapter(): BluetoothAdapter? {
        val ctx = context ?: return null
        return (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    }

    private fun adapterState(): String {
        val ctx = context ?: return "unknown"
        if (!ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return "unsupported"
        }
        val adapter = adapter() ?: return "unsupported"
        if (!hasPermissions()) return "unauthorized"
        return try {
            if (adapter.isEnabled) "on" else "off"
        } catch (_: SecurityException) {
            "unauthorized"
        }
    }

    private fun emitAdapter() {
        val state = adapterState()
        eventSink?.success(mapOf("type" to "adapter", "state" to state))
    }

    @SuppressLint("MissingPermission")
    private fun requestEnable(): Boolean {
        val act = activity
        if (act != null && hasPermissions()) {
            try {
                act.startActivityForResult(
                    Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE),
                    REQUEST_ENABLE_BT,
                )
                return true
            } catch (_: Exception) {
            }
        }
        return openBluetoothSettings()
    }

    private fun openBluetoothSettings(): Boolean {
        val ctx = activity ?: context ?: return false
        return try {
            val intent = Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            if (ctx !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun hasPermissions(): Boolean {
        val ctx = context ?: return false
        fun granted(p: String) =
            ContextCompat.checkSelfPermission(ctx, p) == PackageManager.PERMISSION_GRANTED
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            granted(Manifest.permission.BLUETOOTH_SCAN) &&
                granted(Manifest.permission.BLUETOOTH_ADVERTISE) &&
                granted(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            granted(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    // ── Radio lifecycle ────────────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun start(): Boolean {
        val ctx = context ?: return false
        if (sessionId.length != 8 || peerId.length != 8) return false
        if (!hasPermissions()) return false
        val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: return false
        val adapter = manager.adapter ?: return false
        if (!adapter.isEnabled) return false

        teardownRadio()

        // GATT inbox other peers write frames into.
        try {
            val server = manager.openGattServer(ctx, serverCallback)
            if (server != null) {
                val service = BluetoothGattService(
                    SERVICE_UUID,
                    BluetoothGattService.SERVICE_TYPE_PRIMARY,
                )
                val inbox = BluetoothGattCharacteristic(
                    INBOX_UUID,
                    BluetoothGattCharacteristic.PROPERTY_WRITE,
                    BluetoothGattCharacteristic.PERMISSION_WRITE,
                )
                service.addCharacteristic(inbox)
                server.addService(service)
                gattServer = server
            }
        } catch (e: Exception) {
            eventSink?.error("gatt_server", e.message, null)
        }

        var advertising = false
        try {
            advertiser = adapter.bluetoothLeAdvertiser
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .setConnectable(true)
                .build()
            val payload = (sessionId + peerId).toByteArray(Charsets.UTF_8)
            val data = AdvertiseData.Builder()
                .addManufacturerData(MANUFACTURER_ID, payload)
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .build()
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {}
                override fun onStartFailure(errorCode: Int) {
                    main.post { eventSink?.error("advertise_failure", "code=$errorCode", null) }
                }
            }
            advertiseCallback = callback
            advertiser?.startAdvertising(settings, data, callback)
            advertising = advertiser != null
        } catch (e: Exception) {
            eventSink?.error("advertise_exception", e.message, null)
        }

        var scanning = false
        try {
            scanner = adapter.bluetoothLeScanner
            val callback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult?) {
                    if (result != null) main.post { handleScanResult(result) }
                }

                override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                    val copy = results?.toList() ?: return
                    main.post { copy.forEach { handleScanResult(it) } }
                }

                override fun onScanFailed(errorCode: Int) {
                    main.post { eventSink?.error("scan_failure", "code=$errorCode", null) }
                }
            }
            scanCallback = callback
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()
            scanner?.startScan(emptyList(), settings, callback)
            scanning = scanner != null
        } catch (e: Exception) {
            eventSink?.error("scan_exception", e.message, null)
        }
        return advertising || scanning
    }

    private fun stop() {
        teardownRadio()
        devices.clear()
        lastSeen.clear()
        lastAnnounce.clear()
    }

    @SuppressLint("MissingPermission")
    private fun teardownRadio() {
        try {
            advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (_: Exception) {
        }
        try {
            scanCallback?.let { scanner?.stopScan(it) }
        } catch (_: Exception) {
        }
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        advertiseCallback = null
        scanCallback = null
        advertiser = null
        scanner = null
        gattServer = null
        activeTimeout?.let { main.removeCallbacks(it) }
        activeTimeout = null
        activeJob = null
        urgent.clear()
        announces.clear()
        for (peer in links.keys.toList()) closeLink(peer)
        partials.clear()
    }

    // ── Advertisements → sightings ─────────────────────────────────────────

    private fun handleScanResult(result: ScanResult) {
        val record = result.scanRecord ?: return
        val text = record.getManufacturerSpecificData(MANUFACTURER_ID)
            ?.let { String(it, Charsets.UTF_8) }
            ?: record.deviceName
                ?.takeIf { it.startsWith(LOCAL_NAME_PREFIX) }
                ?.substring(LOCAL_NAME_PREFIX.length)
            ?: return
        if (text.length < 16) return
        if (text.substring(0, 8) != sessionId) return
        val remotePeer = text.substring(8, 16)
        if (remotePeer == peerId) return

        val now = System.currentTimeMillis()
        devices[remotePeer] = result.device
        lastSeen[remotePeer] = now
        val rssi = result.rssi
        val distance = 10.0.pow((NOMINAL_TX_POWER - rssi) / 20.0)
        eventSink?.success(
            mapOf(
                "type" to "sighting",
                "peerId" to remotePeer,
                "displayName" to "Peer $remotePeer",
                "distanceMeters" to distance,
                "rssi" to rssi,
                "lastSeenMs" to now,
            ),
        )
    }

    // ── GATT server: receive ───────────────────────────────────────────────

    private val serverCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            val ok = device != null &&
                characteristic?.uuid == INBOX_UUID &&
                value != null &&
                !preparedWrite &&
                offset == 0
            if (responseNeeded && device != null) {
                try {
                    gattServer?.sendResponse(
                        device,
                        requestId,
                        if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                        0,
                        null,
                    )
                } catch (_: Exception) {
                }
            }
            if (ok) {
                val address = device!!.address
                val chunk = value!!.copyOf()
                main.post { onChunk(address, chunk) }
            }
        }
    }

    private fun onChunk(address: String, chunk: ByteArray) {
        if (chunk.size < CHUNK_HEADER) return
        val id = chunk[0].toInt() and 0xff
        val index = chunk[1].toInt() and 0xff
        val count = chunk[2].toInt() and 0xff
        if (count == 0 || index >= count) return

        val now = System.currentTimeMillis()
        partials.entries.removeAll { now - it.value.startedAt > REASSEMBLY_TIMEOUT_MS }

        val key = "$address:$id"
        var partial = partials[key]
        if (partial == null || partial.count != count) {
            partial = Partial(count, now)
            partials[key] = partial
        }
        if (partial.parts[index] == null) {
            partial.parts[index] = chunk.copyOfRange(CHUNK_HEADER, chunk.size)
            partial.received++
        }
        if (partial.received < count) return
        partials.remove(key)

        var total = 0
        for (p in partial.parts) total += p!!.size
        val frame = ByteArray(total)
        var offset = 0
        for (p in partial.parts) {
            System.arraycopy(p!!, 0, frame, offset, p.size)
            offset += p.size
        }
        eventSink?.success(mapOf("type" to "frame", "data" to frame))
    }

    // ── GATT client: send ──────────────────────────────────────────────────

    private fun send(data: ByteArray, to: List<String>, announce: Boolean): Int {
        val now = System.currentTimeMillis()
        val targets = if (to.isEmpty()) {
            devices.keys.filter { now - (lastSeen[it] ?: 0L) < PEER_FRESH_MS }
        } else {
            to.filter { devices.containsKey(it) }
        }
        var queued = 0
        for (target in targets) {
            if (announce) {
                val last = lastAnnounce[target]
                if (last != null && now - last < ANNOUNCE_INTERVAL_MS) continue
                lastAnnounce[target] = now
            }
            val job = SendJob(target, data, nextMessageId)
            nextMessageId = (nextMessageId + 1) and 0xff
            val queue = if (announce) announces else urgent
            if (urgent.size + announces.size >= MAX_QUEUE) {
                // Shed the oldest low-priority work first.
                if (announces.isNotEmpty()) announces.pollFirst() else urgent.pollFirst()
            }
            queue.addLast(job)
            queued++
        }
        pump()
        return queued
    }

    @SuppressLint("MissingPermission")
    private fun pump() {
        if (activeJob != null) return
        val job = urgent.pollFirst() ?: announces.pollFirst() ?: return
        val device = devices[job.peerId]
        val ctx = context
        if (device == null || ctx == null) {
            pump()
            return
        }
        activeJob = job
        val timeout = Runnable { if (activeJob === job) failActive() }
        activeTimeout = timeout
        main.postDelayed(timeout, JOB_TIMEOUT_MS)

        val link = links[job.peerId]
        if (link != null) {
            link.closeTask?.let { main.removeCallbacks(it) }
            link.closeTask = null
            if (link.ready) writeJob(link, job)
            return // Otherwise the connection in progress will pick it up.
        }
        try {
            val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(ctx, false, clientCallback(job.peerId), BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(ctx, false, clientCallback(job.peerId))
            }
            if (gatt == null) {
                failActive()
            } else {
                links[job.peerId] = Link(gatt)
            }
        } catch (_: Exception) {
            failActive()
        }
    }

    private fun clientCallback(peer: String) = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
            main.post {
                val link = links[peer]
                if (gatt == null || link == null || link.gatt !== gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                    val requested = try {
                        gatt.requestMtu(DESIRED_MTU)
                    } catch (_: Exception) {
                        false
                    }
                    if (!requested) discover(gatt)
                } else {
                    closeLink(peer)
                    if (activeJob?.peerId == peer) failActive()
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
            main.post {
                val link = links[peer]
                if (gatt == null || link == null || link.gatt !== gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) link.mtu = mtu
                discover(gatt)
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt?, status: Int) {
            main.post {
                val link = links[peer]
                if (gatt == null || link == null || link.gatt !== gatt) return@post
                val inbox = gatt.getService(SERVICE_UUID)?.getCharacteristic(INBOX_UUID)
                if (status != BluetoothGatt.GATT_SUCCESS || inbox == null) {
                    closeLink(peer)
                    if (activeJob?.peerId == peer) failActive()
                    return@post
                }
                link.inbox = inbox
                link.ready = true
                val job = activeJob
                if (job != null && job.peerId == peer) writeJob(link, job)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?,
            status: Int,
        ) {
            main.post {
                val link = links[peer]
                if (gatt == null || link == null || link.gatt !== gatt) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failActive()
                } else {
                    writeNextChunk(peer, link)
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun discover(gatt: BluetoothGatt) {
        val started = try {
            gatt.discoverServices()
        } catch (_: Exception) {
            false
        }
        if (!started) {
            val peer = links.entries.firstOrNull { it.value.gatt === gatt }?.key ?: return
            closeLink(peer)
            if (activeJob?.peerId == peer) failActive()
        }
    }

    private fun writeJob(link: Link, job: SendJob) {
        // Each chunk must fit one ATT write (MTU - 3), so no long writes.
        val payload = max(20, link.mtu - 3) - CHUNK_HEADER
        val count = max(1, (job.data.size + payload - 1) / payload)
        if (count > 255) {
            failActive()
            return
        }
        link.chunks.clear()
        for (i in 0 until count) {
            val start = i * payload
            val end = min(start + payload, job.data.size)
            val chunk = ByteArray(CHUNK_HEADER + (end - start))
            chunk[0] = job.messageId.toByte()
            chunk[1] = i.toByte()
            chunk[2] = count.toByte()
            System.arraycopy(job.data, start, chunk, CHUNK_HEADER, end - start)
            link.chunks.addLast(chunk)
        }
        writeNextChunk(job.peerId, link)
    }

    @SuppressLint("MissingPermission")
    private fun writeNextChunk(peer: String, link: Link) {
        val chunk = link.chunks.pollFirst()
        if (chunk == null) {
            completeActive(peer, link)
            return
        }
        val inbox = link.inbox
        if (inbox == null) {
            failActive()
            return
        }
        val accepted = try {
            if (Build.VERSION.SDK_INT >= 33) {
                link.gatt.writeCharacteristic(
                    inbox,
                    chunk,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                legacyWrite(link.gatt, inbox, chunk)
            }
        } catch (_: Exception) {
            false
        }
        if (!accepted) failActive()
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun legacyWrite(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
    ): Boolean {
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        characteristic.value = value
        return gatt.writeCharacteristic(characteristic)
    }

    private fun completeActive(peer: String, link: Link) {
        activeTimeout?.let { main.removeCallbacks(it) }
        activeTimeout = null
        activeJob = null
        // Keep the connection briefly: replies often follow right away.
        val close = Runnable { closeLink(peer) }
        link.closeTask = close
        main.postDelayed(close, IDLE_CLOSE_MS)
        pump()
    }

    private fun failActive() {
        activeTimeout?.let { main.removeCallbacks(it) }
        activeTimeout = null
        val job = activeJob
        activeJob = null
        // Dart retries anything important; drop and move on.
        if (job != null) closeLink(job.peerId)
        pump()
    }

    @SuppressLint("MissingPermission")
    private fun closeLink(peer: String) {
        val link = links.remove(peer) ?: return
        link.closeTask?.let { main.removeCallbacks(it) }
        try {
            link.gatt.disconnect()
        } catch (_: Exception) {
        }
        try {
            link.gatt.close()
        } catch (_: Exception) {
        }
    }
}
