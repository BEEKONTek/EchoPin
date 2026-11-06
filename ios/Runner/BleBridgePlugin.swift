import CoreBluetooth
import Flutter
import UIKit

/// Native half of the BLE transport. Mirrors BleBridgePlugin.kt exactly so
/// iPhones and Android phones interoperate:
///
/// - Advertises "EP" + sessionId + peerId as the local name (iOS cannot
///   advertise manufacturer data; Android peers use manufacturer data and
///   both scanners accept either form).
/// - Scans for the same session; RSSI gives a distance estimate.
/// - Moves opaque frames over a GATT inbox characteristic, split into chunks
///   `[messageId, index, count, payload...]` that each fit one ATT write.
///
/// Every frame is encrypted and signed in Dart; nothing here sees secrets.
/// All CoreBluetooth objects and mutable state live on `queue`; Flutter
/// results and events are always delivered on the main thread.
public class BleBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let nominalTxPower: Double = -59.0
    private static let localNamePrefix = "EP"
    private static let serviceUUID = CBUUID(string: "6E3F0001-8C2A-4E5B-9D1E-3C7A5B2F0E01")
    private static let inboxUUID = CBUUID(string: "6E3F0002-8C2A-4E5B-9D1E-3C7A5B2F0E01")
    private static let chunkHeader = 3
    private static let jobTimeout: TimeInterval = 10
    private static let idleClose: TimeInterval = 15
    private static let announceInterval: TimeInterval = 60
    private static let peerFresh: TimeInterval = 30
    private static let reassemblyTimeout: TimeInterval = 15
    private static let maxQueue = 64

    private let queue = DispatchQueue(label: "echo_pin.ble")

    /// Main thread only.
    private var eventSink: FlutterEventSink?

    private var peripheralManager: CBPeripheralManager?
    private var centralManager: CBCentralManager?
    private var powerAlertManager: CBCentralManager?
    private var sessionId = ""
    private var peerId = ""
    private var running = false
    private var serviceAdded = false

    private var peripherals: [String: CBPeripheral] = [:]
    private var lastSeen: [String: Date] = [:]
    private var lastAnnounce: [String: Date] = [:]

    private struct Job {
        let peerId: String
        let data: Data
        let messageId: UInt8
    }

    private var urgent: [Job] = []
    private var announces: [Job] = []
    private var active: Job?
    private var activeToken = 0
    private var nextMessageId: UInt8 = 0
    private var pendingChunks: [Data] = []
    private var inboxes: [UUID: CBCharacteristic] = [:]
    private var idleTimers: [UUID: DispatchWorkItem] = [:]

    private final class Partial {
        let count: Int
        var parts: [Data?]
        var received = 0
        let started = Date()

        init(count: Int) {
            self.count = count
            self.parts = Array(repeating: nil, count: count)
        }
    }

    private var partials: [String: Partial] = [:]

    // MARK: - Flutter plumbing

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methods = FlutterMethodChannel(
            name: "echo_pin/ble/methods",
            binaryMessenger: registrar.messenger()
        )
        let events = FlutterEventChannel(
            name: "echo_pin/ble/events",
            binaryMessenger: registrar.messenger()
        )
        let instance = BleBridgePlugin()
        registrar.addMethodCallDelegate(instance, channel: methods)
        events.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "ping":
            result(true)
        case "adapterState":
            queue.async {
                let state = self.adapterState()
                DispatchQueue.main.async { result(state) }
            }
        case "requestEnable":
            queue.async {
                let shown = self.showPowerAlert()
                DispatchQueue.main.async { result(shown) }
            }
        case "start":
            guard let sid = args?["sessionId"] as? String,
                  let pid = args?["peerId"] as? String,
                  sid.count == 8, pid.count == 8
            else {
                result(false)
                return
            }
            queue.async {
                self.sessionId = sid
                self.peerId = pid
                self.startRadios()
                DispatchQueue.main.async { result(true) }
            }
        case "send":
            guard let typed = args?["data"] as? FlutterStandardTypedData else {
                result(0)
                return
            }
            let data = Data(typed.data)
            let to = (args?["to"] as? [String]) ?? []
            let announce = (args?["announce"] as? Bool) ?? false
            queue.async {
                let queued = self.enqueue(data: data, to: to, announce: announce)
                DispatchQueue.main.async { result(queued) }
            }
        case "stop":
            queue.async {
                self.stopRadios()
                DispatchQueue.main.async { result(nil) }
            }
        case "inject":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        queue.async { self.emitAdapter() }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }

    // MARK: - Adapter state

    private func adapterState() -> String {
        if #available(iOS 13.1, *) {
            switch CBManager.authorization {
            case .denied, .restricted:
                return "unauthorized"
            default:
                break
            }
        }
        guard let central = centralManager else { return "unknown" }
        switch central.state {
        case .poweredOn:
            return "on"
        case .poweredOff:
            return "off"
        case .unauthorized:
            return "unauthorized"
        case .unsupported:
            return "unsupported"
        default:
            return "unknown"
        }
    }

    private func emitAdapter() {
        emit(["type": "adapter", "state": adapterState()])
    }

    /// iOS has no API to switch Bluetooth on. A central manager created with
    /// this option makes iOS show its own "Turn On Bluetooth" alert.
    private func showPowerAlert() -> Bool {
        powerAlertManager = CBCentralManager(
            delegate: nil,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        return true
    }

    // MARK: - Radio lifecycle

    private func startRadios() {
        running = true
        if centralManager == nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: true]
            )
        }
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue, options: nil)
        }
        if let pm = peripheralManager, pm.state == .poweredOn {
            publishService(pm)
            beginAdvertising(pm)
        }
        if let cm = centralManager, cm.state == .poweredOn {
            beginScanning(cm)
        }
    }

    private func publishService(_ pm: CBPeripheralManager) {
        guard !serviceAdded else { return }
        let inbox = CBMutableCharacteristic(
            type: BleBridgePlugin.inboxUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: BleBridgePlugin.serviceUUID, primary: true)
        service.characteristics = [inbox]
        pm.add(service)
        serviceAdded = true
    }

    private func beginAdvertising(_ pm: CBPeripheralManager) {
        if pm.isAdvertising { pm.stopAdvertising() }
        pm.startAdvertising([
            CBAdvertisementDataLocalNameKey: BleBridgePlugin.localNamePrefix + sessionId + peerId,
        ])
    }

    private func beginScanning(_ cm: CBCentralManager) {
        if cm.isScanning { cm.stopScan() }
        cm.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func stopRadios() {
        running = false
        if let pm = peripheralManager, pm.state == .poweredOn {
            pm.stopAdvertising()
            if serviceAdded { pm.removeAllServices() }
        }
        serviceAdded = false
        if let cm = centralManager, cm.state == .poweredOn {
            cm.stopScan()
            for p in peripherals.values where p.state != .disconnected {
                cm.cancelPeripheralConnection(p)
            }
        }
        for timer in idleTimers.values {
            timer.cancel()
        }
        idleTimers.removeAll()
        inboxes.removeAll()
        peripherals.removeAll()
        lastSeen.removeAll()
        lastAnnounce.removeAll()
        urgent.removeAll()
        announces.removeAll()
        active = nil
        activeToken += 1
        pendingChunks.removeAll()
        partials.removeAll()
    }

    // MARK: - Sending

    private func enqueue(data: Data, to: [String], announce: Bool) -> Int {
        let now = Date()
        let targets: [String]
        if to.isEmpty {
            targets = peripherals.keys.filter { key in
                guard let seen = lastSeen[key] else { return false }
                return now.timeIntervalSince(seen) < BleBridgePlugin.peerFresh
            }
        } else {
            targets = to.filter { peripherals[$0] != nil }
        }
        var queued = 0
        for target in targets {
            if announce {
                if let last = lastAnnounce[target],
                   now.timeIntervalSince(last) < BleBridgePlugin.announceInterval {
                    continue
                }
                lastAnnounce[target] = now
            }
            let job = Job(peerId: target, data: data, messageId: nextMessageId)
            nextMessageId = nextMessageId &+ 1
            if urgent.count + announces.count >= BleBridgePlugin.maxQueue {
                // Shed the oldest low-priority work first.
                if !announces.isEmpty {
                    announces.removeFirst()
                } else if !urgent.isEmpty {
                    urgent.removeFirst()
                }
            }
            if announce {
                announces.append(job)
            } else {
                urgent.append(job)
            }
            queued += 1
        }
        pump()
        return queued
    }

    private func pump() {
        while active == nil {
            let next: Job
            if !urgent.isEmpty {
                next = urgent.removeFirst()
            } else if !announces.isEmpty {
                next = announces.removeFirst()
            } else {
                return
            }
            guard let central = centralManager,
                  central.state == .poweredOn,
                  let peripheral = peripherals[next.peerId]
            else {
                continue
            }
            active = next
            activeToken += 1
            let token = activeToken
            queue.asyncAfter(deadline: .now() + BleBridgePlugin.jobTimeout) { [weak self] in
                guard let self = self, self.activeToken == token, self.active != nil else { return }
                self.failActive()
            }
            idleTimers.removeValue(forKey: peripheral.identifier)?.cancel()
            if peripheral.state == .connected {
                if let inbox = inboxes[peripheral.identifier] {
                    write(next, to: peripheral, inbox: inbox)
                } else {
                    peripheral.delegate = self
                    peripheral.discoverServices([BleBridgePlugin.serviceUUID])
                }
            } else {
                central.connect(peripheral, options: nil)
            }
        }
    }

    private func write(_ job: Job, to peripheral: CBPeripheral, inbox: CBCharacteristic) {
        // The without-response length is exactly ATT_MTU - 3, so each chunk
        // fits a single ATT write and iOS never falls back to a long write.
        let limit = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        let payload = limit - BleBridgePlugin.chunkHeader
        let total = job.data.count
        let count = max(1, (total + payload - 1) / payload)
        guard count <= 255 else {
            failActive()
            return
        }
        var chunks: [Data] = []
        chunks.reserveCapacity(count)
        for index in 0..<count {
            let start = index * payload
            let end = min(start + payload, total)
            var chunk = Data([job.messageId, UInt8(index), UInt8(count)])
            chunk.append(job.data.subdata(in: start..<end))
            chunks.append(chunk)
        }
        pendingChunks = chunks
        writeNext(to: peripheral, inbox: inbox)
    }

    private func writeNext(to peripheral: CBPeripheral, inbox: CBCharacteristic) {
        guard !pendingChunks.isEmpty else {
            complete(peripheral)
            return
        }
        let chunk = pendingChunks.removeFirst()
        peripheral.writeValue(chunk, for: inbox, type: .withResponse)
    }

    private func complete(_ peripheral: CBPeripheral) {
        active = nil
        activeToken += 1
        // Keep the connection briefly: replies often follow right away.
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.idleTimers.removeValue(forKey: peripheral.identifier)
            if self.centralManager?.state == .poweredOn {
                self.centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
        idleTimers[peripheral.identifier] = item
        queue.asyncAfter(deadline: .now() + BleBridgePlugin.idleClose, execute: item)
        pump()
    }

    /// Drops the active job. Dart retries anything important.
    private func failActive() {
        guard let job = active else { return }
        active = nil
        activeToken += 1
        pendingChunks.removeAll()
        if let peripheral = peripherals[job.peerId] {
            inboxes.removeValue(forKey: peripheral.identifier)
            if peripheral.state != .disconnected, centralManager?.state == .poweredOn {
                centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
        pump()
    }

    private func isActive(_ peripheral: CBPeripheral) -> Bool {
        guard let job = active, let p = peripherals[job.peerId] else { return false }
        return p.identifier == peripheral.identifier
    }

    // MARK: - Receiving

    private func onChunk(from central: String, chunk: Data) {
        let bytes = [UInt8](chunk)
        guard bytes.count >= BleBridgePlugin.chunkHeader else { return }
        let id = bytes[0]
        let index = Int(bytes[1])
        let count = Int(bytes[2])
        guard count > 0, index < count else { return }

        let now = Date()
        partials = partials.filter {
            now.timeIntervalSince($0.value.started) < BleBridgePlugin.reassemblyTimeout
        }

        let key = "\(central):\(id)"
        let partial: Partial
        if let existing = partials[key], existing.count == count {
            partial = existing
        } else {
            partial = Partial(count: count)
            partials[key] = partial
        }
        if partial.parts[index] == nil {
            partial.parts[index] = Data(bytes[BleBridgePlugin.chunkHeader...])
            partial.received += 1
        }
        guard partial.received == count else { return }
        partials.removeValue(forKey: key)

        var frame = Data()
        for part in partial.parts {
            if let part = part { frame.append(part) }
        }
        emit(["type": "frame", "data": FlutterStandardTypedData(bytes: frame)])
    }
}

// MARK: - Peripheral role (inbox)

extension BleBridgePlugin: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            if running {
                publishService(peripheral)
                beginAdvertising(peripheral)
            }
        } else {
            serviceAdded = false
        }
        emitAdapter()
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        guard let first = requests.first else { return }
        var ok = true
        for request in requests {
            guard request.characteristic.uuid == BleBridgePlugin.inboxUUID,
                  request.offset == 0,
                  let value = request.value
            else {
                ok = false
                continue
            }
            onChunk(from: request.central.identifier.uuidString, chunk: value)
        }
        peripheral.respond(to: first, withResult: ok ? .success : .writeNotPermitted)
    }
}

// MARK: - Central role (scan + send)

extension BleBridgePlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if running { beginScanning(central) }
        } else {
            // Connections are gone; forget them so later sends reconnect.
            inboxes.removeAll()
            if active != nil { failActive() }
        }
        emitAdapter()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        var payload: String?
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           data.count >= 18 {
            // CoreBluetooth includes the 2-byte company id before the payload.
            payload = String(data: Data(data.dropFirst(2)), encoding: .utf8)
        } else if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                  name.hasPrefix(BleBridgePlugin.localNamePrefix) {
            payload = String(name.dropFirst(BleBridgePlugin.localNamePrefix.count))
        }
        guard let text = payload, text.count >= 16 else { return }
        if String(text.prefix(8)) != sessionId { return }
        let remotePeer = String(text.dropFirst(8).prefix(8))
        if remotePeer == peerId { return }
        let rssiValue = RSSI.intValue
        if rssiValue == 127 { return } // "RSSI not available"

        peripherals[remotePeer] = peripheral
        let now = Date()
        lastSeen[remotePeer] = now
        let ratio = (BleBridgePlugin.nominalTxPower - Double(rssiValue)) / 20.0
        emit([
            "type": "sighting",
            "peerId": remotePeer,
            "displayName": "Peer \(remotePeer)",
            "distanceMeters": pow(10.0, ratio),
            "rssi": rssiValue,
            "lastSeenMs": Int(now.timeIntervalSince1970 * 1000),
        ])
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([BleBridgePlugin.serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        if isActive(peripheral) { failActive() }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        inboxes.removeValue(forKey: peripheral.identifier)
        idleTimers.removeValue(forKey: peripheral.identifier)?.cancel()
        if isActive(peripheral) { failActive() }
    }
}

// MARK: - GATT client callbacks

extension BleBridgePlugin: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: {
                  $0.uuid == BleBridgePlugin.serviceUUID
              })
        else {
            if isActive(peripheral) { failActive() }
            return
        }
        peripheral.discoverCharacteristics([BleBridgePlugin.inboxUUID], for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let inbox = service.characteristics?.first(where: {
                  $0.uuid == BleBridgePlugin.inboxUUID
              })
        else {
            if isActive(peripheral) { failActive() }
            return
        }
        inboxes[peripheral.identifier] = inbox
        if let job = active, isActive(peripheral) {
            write(job, to: peripheral, inbox: inbox)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isActive(peripheral) else { return }
        if error != nil {
            failActive()
            return
        }
        writeNext(to: peripheral, inbox: characteristic)
    }
}
