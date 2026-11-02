import Flutter
import CoreBluetooth

public class BleBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let nominalTxPower: Double = -59.0
    private var eventSink: FlutterEventSink?
    private var peripheralManager: CBPeripheralManager?
    private var centralManager: CBCentralManager?
    private var sessionId: String = ""
    private var peerId: String = ""

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
        switch call.method {
        case "ping":
            result(true)
        case "start":
            guard let args = call.arguments as? [String: Any],
                  let sid = args["sessionId"] as? String,
                  let pid = args["peerId"] as? String,
                  sid.count == 8, pid.count == 8 else {
                result(false)
                return
            }
            sessionId = sid
            peerId = pid
            start()
            result(true)
        case "stop":
            stop()
            result(nil)
        case "inject":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start() {
        let queue = DispatchQueue(label: "echo_pin.ble")
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue)
        }
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: queue)
        }
        if let pm = peripheralManager, pm.state == .poweredOn {
            beginAdvertising()
        }
        if let cm = centralManager, cm.state == .poweredOn {
            beginScanning()
        }
    }

    private func stop() {
        peripheralManager?.stopAdvertising()
        centralManager?.stopScan()
        peripheralManager = nil
        centralManager = nil
    }

    private func beginAdvertising() {
        guard let pm = peripheralManager else { return }
        let payload = (sessionId + peerId).data(using: .utf8) ?? Data()
        pm.startAdvertising([CBAdvertisementDataManufacturerDataKey: payload])
    }

    private func beginScanning() {
        guard let cm = centralManager else { return }
        cm.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}

extension BleBridgePlugin: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            beginAdvertising()
        }
    }
}

extension BleBridgePlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            beginScanning()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let text = String(data: data, encoding: .utf8),
              text.count >= 16 else { return }
        if String(text.prefix(8)) != sessionId { return }
        let remotePeer = String(text.dropFirst(8).prefix(8))
        if remotePeer == peerId { return }
        let rssiValue = RSSI.intValue
        let ratio = (BleBridgePlugin.nominalTxPower - Double(rssiValue)) / 20.0
        let distance = pow(10.0, ratio)
        eventSink?([
            "peerId": remotePeer,
            "displayName": "Peer \(remotePeer)",
            "distanceMeters": distance,
            "rssi": rssiValue,
            "lastSeenMs": Int(Date().timeIntervalSince1970 * 1000),
        ])
    }
}
