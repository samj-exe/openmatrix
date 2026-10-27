import Combine
import CoreBluetooth
import Foundation

struct MatrixDisplay: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let isLikelyIDotMatrix: Bool
}

@MainActor
final class IDotMatrixBluetooth: NSObject, ObservableObject {
    static let shared = IDotMatrixBluetooth()

    @Published private(set) var displays: [MatrixDisplay] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isSending = false
    @Published private(set) var selectedDisplayName: String?
    @Published private(set) var bluetoothStatus = "Tap Scan to request Bluetooth access."

    private static let serviceUUID = CBUUID(string: "000000FA-0000-1000-8000-00805F9B34FB")
    private static let writeCharacteristicUUID = CBUUID(string: "0000FA02-0000-1000-8000-00805F9B34FB")
    private let defaults = UserDefaults.standard
    private var central: CBCentralManager?
    private var foundPeripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var readinessWaiter: CheckedContinuation<Void, Error>?
    private var readinessWaiterID: UUID?
    private var connectionWaiter: CheckedContinuation<Void, Error>?
    private var writeReadyWaiter: CheckedContinuation<Void, Error>?

    private override init() {
        super.init()
        selectedDisplayName = defaults.string(forKey: "selectedDisplayName")
    }

    func select(_ display: MatrixDisplay) {
        defaults.set(display.id.uuidString, forKey: "selectedDisplayID")
        defaults.set(display.name, forKey: "selectedDisplayName")
        selectedDisplayName = display.name
    }

    func scan() async throws {
        guard !isScanning, !isSending else { return }
        isScanning = true
        bluetoothStatus = "Requesting Bluetooth access…"

        do {
            try await waitUntilReady()
        } catch {
            isScanning = false
            bluetoothStatus = error.localizedDescription
            throw error
        }

        displays = []
        foundPeripherals = [:]
        guard let central, central.state == .poweredOn else {
            isScanning = false
            bluetoothStatus = "Bluetooth is not powered on."
            throw MatrixError.bluetoothUnavailable
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        bluetoothStatus = "Scanning for nearby Bluetooth displays…"

        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            central.stopScan()
            isScanning = false
            bluetoothStatus = "Scan cancelled."
            throw error
        }
        central.stopScan()
        isScanning = false
        bluetoothStatus = displays.isEmpty
            ? "No nearby Bluetooth devices found. Make sure the display is on, then scan again."
            : "Found \(displays.count) nearby Bluetooth device(s). Select your display."
    }

    func sendImage(_ imageData: Data) async throws {
        guard let identifier = defaults.string(forKey: "selectedDisplayID"),
              let uuid = UUID(uuidString: identifier) else {
            throw MatrixError.noDisplaySelected
        }
        let frame = try ImageFrameEncoder.rgbFrame(from: imageData)
        try await waitUntilReady()
        guard let central else {
            throw MatrixError.bluetoothUnavailable
        }

        guard let peripheral = foundPeripherals[uuid]
                ?? central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            throw MatrixError.displayUnavailable
        }

        isSending = true
        defer {
            isSending = false
            central.cancelPeripheralConnection(peripheral)
            activePeripheral = nil
            writeCharacteristic = nil
        }

        try await connect(to: peripheral)
        guard let characteristic = writeCharacteristic else {
            throw MatrixError.characteristicUnavailable
        }

        try await write(Data([0x05, 0x00, 0x04, 0x01, 0x01]), to: peripheral, characteristic: characteristic)
        try await Task.sleep(for: .milliseconds(100))
        try await write(Self.packetize(frame), to: peripheral, characteristic: characteristic)
        try await Task.sleep(for: .milliseconds(100))
    }

    private func waitUntilReady() async throws {
        switch CBManager.authorization {
        case .denied:
            throw MatrixError.permissionDenied
        case .restricted:
            throw MatrixError.permissionRestricted
        case .notDetermined, .allowedAlways:
            break
        @unknown default:
            break
        }

        if let central, central.state != .unknown, central.state != .resetting {
            try checkBluetoothState(central.state)
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            let waiterID = UUID()
            readinessWaiterID = waiterID
            readinessWaiter = continuation
            if central == nil {
                central = CBCentralManager(delegate: self, queue: .main)
            } else {
                bluetoothStatus = "Waiting for iOS Bluetooth authorization…"
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self,
                      self.readinessWaiterID == waiterID,
                      let waiter = self.readinessWaiter else { return }
                self.readinessWaiter = nil
                self.readinessWaiterID = nil
                if self.central?.state == .unknown || self.central?.state == .resetting {
                    self.central = nil
                }
                self.bluetoothStatus = MatrixError.bluetoothTimedOut.localizedDescription
                waiter.resume(throwing: MatrixError.bluetoothTimedOut)
            }
        }
    }

    private func checkBluetoothState(_ state: CBManagerState) throws {
        switch state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth ready. Searching for displays…"
        case .poweredOff:
            throw MatrixError.bluetoothPoweredOff
        case .unauthorized:
            throw MatrixError.permissionDenied
        case .unsupported:
            throw MatrixError.bluetoothUnsupported
        case .unknown, .resetting:
            throw MatrixError.bluetoothTimedOut
        @unknown default:
            throw MatrixError.bluetoothUnavailable
        }
    }

    private func connect(to peripheral: CBPeripheral) async throws {
        if peripheral.state == .connected, writeCharacteristic != nil {
            return
        }

        activePeripheral = peripheral
        peripheral.delegate = self
        guard let central else {
            throw MatrixError.bluetoothUnavailable
        }
        try await withCheckedThrowingContinuation { continuation in
            connectionWaiter = continuation
            central.connect(peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak peripheral] in
                guard let self, self.connectionWaiter != nil else { return }
                self.connectionWaiter?.resume(throwing: MatrixError.connectionTimedOut)
                self.connectionWaiter = nil
                if let peripheral {
                    self.central?.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }

    private func write(_ data: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic) async throws {
        let maximumWriteLength = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0

        while offset < data.count {
            if !peripheral.canSendWriteWithoutResponse {
                try await withCheckedThrowingContinuation { continuation in
                    writeReadyWaiter = continuation
                    if peripheral.canSendWriteWithoutResponse {
                        writeReadyWaiter = nil
                        continuation.resume()
                    }
                }
            }
            let end = min(offset + maximumWriteLength, data.count)
            peripheral.writeValue(data.subdata(in: offset..<end), for: characteristic, type: .withoutResponse)
            offset = end
        }
    }

    private static func packetize(_ frame: Data) -> Data {
        let chunkSize = 4096
        var packet = Data()
        var offset = 0
        var chunkIndex = 0

        while offset < frame.count {
            let end = min(offset + chunkSize, frame.count)
            let chunk = frame.subdata(in: offset..<end)
            appendUInt16LE(UInt16(chunk.count + 9), to: &packet)
            packet.append(contentsOf: [0x00, 0x00, chunkIndex == 0 ? 0x00 : 0x02])
            appendUInt32LE(UInt32(frame.count), to: &packet)
            packet.append(chunk)
            offset = end
            chunkIndex += 1
        }
        return packet
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8(value >> 24))
    }

    private enum MatrixError: LocalizedError {
        case noDisplaySelected
        case displayUnavailable
        case bluetoothUnavailable
        case permissionDenied
        case permissionRestricted
        case bluetoothPoweredOff
        case bluetoothUnsupported
        case bluetoothTimedOut
        case connectionTimedOut
        case connectionFailed
        case characteristicUnavailable

        var errorDescription: String? {
            switch self {
            case .noDisplaySelected:
                return "Scan for and select an iDotMatrix display in OpenMatrix first."
            case .displayUnavailable:
                return "The selected display was not found. Open OpenMatrix and scan for it again."
            case .bluetoothUnavailable:
                return "Bluetooth is unavailable. Turn on Bluetooth and try again."
            case .permissionDenied:
                return "Bluetooth access is turned off for OpenMatrix. Allow it in Settings > Privacy & Security > Bluetooth, then try again."
            case .permissionRestricted:
                return "Bluetooth access is restricted on this device."
            case .bluetoothPoweredOff:
                return "Turn on Bluetooth in Settings or Control Center, then scan again."
            case .bluetoothUnsupported:
                return "This device does not support Bluetooth Low Energy."
            case .bluetoothTimedOut:
                return "Bluetooth did not finish starting. Check Settings > Privacy & Security > Bluetooth for OpenMatrix. If it is not listed, reinstall the latest build and tap Scan again."
            case .connectionTimedOut:
                return "The display did not connect in time. Move closer and try again."
            case .connectionFailed:
                return "OpenMatrix could not connect to the display."
            case .characteristicUnavailable:
                return "The display does not expose the expected iDotMatrix BLE service."
            }
        }
    }
}

extension IDotMatrixBluetooth: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }

        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth ready."
        case .poweredOff:
            bluetoothStatus = "Bluetooth is off. Turn it on and tap Scan."
        case .unauthorized:
            bluetoothStatus = MatrixError.permissionDenied.localizedDescription
        case .unsupported:
            bluetoothStatus = MatrixError.bluetoothUnsupported.localizedDescription
        case .resetting:
            bluetoothStatus = "Bluetooth is restarting…"
        case .unknown:
            bluetoothStatus = "Waiting for Bluetooth…"
        @unknown default:
            bluetoothStatus = "Bluetooth state unavailable."
        }

        if let waiter = readinessWaiter {
            switch central.state {
            case .poweredOn, .poweredOff, .unauthorized, .unsupported:
                readinessWaiter = nil
                readinessWaiterID = nil
                do {
                    try checkBluetoothState(central.state)
                    waiter.resume()
                } catch {
                    bluetoothStatus = error.localizedDescription
                    waiter.resume(throwing: error)
                }
            case .unknown, .resetting:
                break
            @unknown default:
                readinessWaiter = nil
                readinessWaiterID = nil
                waiter.resume(throwing: MatrixError.bluetoothUnavailable)
            }
        }

        if central.state != .poweredOn {
            if connectionWaiter != nil {
                finishConnection(with: MatrixError.bluetoothUnavailable)
            }
            if let waiter = writeReadyWaiter {
                writeReadyWaiter = nil
                waiter.resume(throwing: MatrixError.bluetoothUnavailable)
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let recognizedByService = services.contains(Self.serviceUUID)
        let normalizedName = name.lowercased()
        let recognizedByName = normalizedName.contains("idotmatrix")
            || normalizedName.contains("idot")
            || normalizedName.hasPrefix("idm")
            || normalizedName.hasPrefix("ipixel")

        foundPeripherals[peripheral.identifier] = peripheral
        let shortID = peripheral.identifier.uuidString.prefix(4)
        let display = MatrixDisplay(
            id: peripheral.identifier,
            name: name.isEmpty ? "Unnamed BLE device (\(shortID))" : name,
            rssi: RSSI.intValue,
            isLikelyIDotMatrix: recognizedByService || recognizedByName
        )
        if let index = displays.firstIndex(where: { $0.id == display.id }) {
            displays[index] = display
        } else {
            displays.append(display)
        }
        displays.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        bluetoothStatus = "Found \(displays.count) nearby device(s)…"
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        finishConnection(with: MatrixError.connectionFailed)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        writeCharacteristic = nil
        if connectionWaiter != nil {
            finishConnection(with: error ?? MatrixError.connectionFailed)
        }
        if let waiter = writeReadyWaiter {
            writeReadyWaiter = nil
            waiter.resume(throwing: error ?? MatrixError.connectionFailed)
        }
    }
}

extension IDotMatrixBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            finishConnection(with: MatrixError.characteristicUnavailable)
            return
        }
        peripheral.discoverCharacteristics([Self.writeCharacteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == Self.writeCharacteristicUUID }) else {
            finishConnection(with: MatrixError.characteristicUnavailable)
            return
        }
        writeCharacteristic = characteristic
        finishConnection(with: nil)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let waiter = writeReadyWaiter else { return }
        writeReadyWaiter = nil
        waiter.resume()
    }

    private func finishConnection(with error: Error?) {
        guard let waiter = connectionWaiter else { return }
        connectionWaiter = nil
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }
}
