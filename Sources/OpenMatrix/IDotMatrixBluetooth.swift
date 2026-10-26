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

    private static let serviceUUID = CBUUID(string: "000000FA-0000-1000-8000-00805F9B34FB")
    private static let writeCharacteristicUUID = CBUUID(string: "0000FA02-0000-1000-8000-00805F9B34FB")
    private let defaults = UserDefaults.standard
    private var central: CBCentralManager!
    private var foundPeripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var readinessWaiter: CheckedContinuation<Void, Error>?
    private var connectionWaiter: CheckedContinuation<Void, Error>?
    private var writeReadyWaiter: CheckedContinuation<Void, Error>?

    private override init() {
        super.init()
        selectedDisplayName = defaults.string(forKey: "selectedDisplayName")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func select(_ display: MatrixDisplay) {
        defaults.set(display.id.uuidString, forKey: "selectedDisplayID")
        defaults.set(display.name, forKey: "selectedDisplayName")
        selectedDisplayName = display.name
    }

    func scan() async throws {
        try await waitUntilReady()
        isScanning = true
        displays = []
        foundPeripherals = [:]
        central.scanForPeripherals(withServices: nil)

        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            central.stopScan()
            isScanning = false
            throw error
        }
        central.stopScan()
        isScanning = false
    }

    func sendImage(_ imageData: Data) async throws {
        guard let identifier = defaults.string(forKey: "selectedDisplayID"),
              let uuid = UUID(uuidString: identifier) else {
            throw MatrixError.noDisplaySelected
        }
        let frame = try ImageFrameEncoder.rgbFrame(from: imageData)
        try await waitUntilReady()

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
        switch central.state {
        case .poweredOn:
            return
        case .poweredOff, .unauthorized, .unsupported:
            throw MatrixError.bluetoothUnavailable
        default:
            try await withCheckedThrowingContinuation { continuation in
                readinessWaiter = continuation
            }
        }
    }

    private func connect(to peripheral: CBPeripheral) async throws {
        if peripheral.state == .connected, writeCharacteristic != nil {
            return
        }

        activePeripheral = peripheral
        peripheral.delegate = self
        try await withCheckedThrowingContinuation { continuation in
            connectionWaiter = continuation
            central.connect(peripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak peripheral] in
                guard let self, self.connectionWaiter != nil else { return }
                self.connectionWaiter?.resume(throwing: MatrixError.connectionTimedOut)
                self.connectionWaiter = nil
                if let peripheral {
                    self.central.cancelPeripheralConnection(peripheral)
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
        if central.state != .poweredOn {
            if connectionWaiter != nil {
                finishConnection(with: MatrixError.bluetoothUnavailable)
            }
            if let waiter = writeReadyWaiter {
                writeReadyWaiter = nil
                waiter.resume(throwing: MatrixError.bluetoothUnavailable)
            }
        }
        guard let waiter = readinessWaiter else { return }
        switch central.state {
        case .poweredOn:
            readinessWaiter = nil
            waiter.resume()
        case .poweredOff, .unauthorized, .unsupported:
            readinessWaiter = nil
            waiter.resume(throwing: MatrixError.bluetoothUnavailable)
        default:
            break
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
