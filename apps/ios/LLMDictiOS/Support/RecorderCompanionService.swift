@preconcurrency import CoreBluetooth
import Foundation
import Observation

struct RecorderDeviceInfo: Equatable, Sendable {
    let protocolVersion: UInt8
    let state: UInt8
    let flags: UInt8
    let microphoneGain: UInt8
    let wavSize: UInt32

    var hasRecording: Bool { flags & 0x01 != 0 && wavSize > 44 }
    var isTransferring: Bool { flags & 0x02 != 0 }

    var stateTitle: String {
        switch state {
        case 0: "Готов"
        case 1: "Идёт запись"
        case 2: "Передача записи"
        case 3: "Ошибка устройства"
        default: "Неизвестное состояние"
        }
    }
}

enum RecorderProtocolEvent: Equatable {
    case info(RecorderDeviceInfo)
    case transferStarted(totalSize: UInt32, offset: UInt32)
    case payload(Data)
    case transferFinished(totalSize: UInt32, crc32: UInt32)
}

enum RecorderProtocolError: LocalizedError, Equatable {
    case invalidFrame
    case unsupportedVersion(UInt8)
    case invalidTransferSize(UInt32)

    var errorDescription: String? {
        switch self {
        case .invalidFrame:
            "Устройство отправило повреждённый BLE-кадр."
        case let .unsupportedVersion(version):
            "Версия BLE-протокола устройства (\(version)) не поддерживается."
        case let .invalidTransferSize(size):
            "Устройство сообщило недопустимый размер записи: \(size) байт."
        }
    }
}

struct RecorderProtocolParser {
    static let maximumWAVSize: UInt32 = 2 * 1024 * 1024

    private var buffer = Data()
    private var rawBytesRemaining = 0

    mutating func consume(_ incoming: Data) throws -> [RecorderProtocolEvent] {
        buffer.append(incoming)
        var events: [RecorderProtocolEvent] = []

        while buffer.isEmpty == false {
            if rawBytesRemaining > 0 {
                let count = min(rawBytesRemaining, buffer.count)
                let payload = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                rawBytesRemaining -= count
                events.append(.payload(payload))
                continue
            }

            guard buffer.count >= 12 else { break }
            let magic = String(decoding: buffer.prefix(4), as: UTF8.self)
            let frame = Data(buffer.prefix(12))
            buffer.removeFirst(12)

            switch magic {
            case "LDI1":
                let version = frame[4]
                guard version == 1 else {
                    throw RecorderProtocolError.unsupportedVersion(version)
                }
                events.append(.info(RecorderDeviceInfo(
                    protocolVersion: version,
                    state: frame[5],
                    flags: frame[6],
                    microphoneGain: frame[7],
                    wavSize: frame.littleEndianUInt32(at: 8)
                )))

            case "LDT1":
                let totalSize = frame.littleEndianUInt32(at: 4)
                let offset = frame.littleEndianUInt32(at: 8)
                guard totalSize <= Self.maximumWAVSize, offset <= totalSize else {
                    throw RecorderProtocolError.invalidTransferSize(totalSize)
                }
                rawBytesRemaining = Int(totalSize - offset)
                events.append(.transferStarted(totalSize: totalSize, offset: offset))

            case "LDE1":
                events.append(.transferFinished(
                    totalSize: frame.littleEndianUInt32(at: 4),
                    crc32: frame.littleEndianUInt32(at: 8)
                ))

            default:
                throw RecorderProtocolError.invalidFrame
            }
        }

        return events
    }
}

struct RecorderCRC32 {
    private var accumulator: UInt32 = 0xFFFF_FFFF

    mutating func update(with data: Data) {
        for byte in data {
            accumulator ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = 0 &- (accumulator & 1)
                accumulator = (accumulator >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
    }

    var value: UInt32 { accumulator ^ 0xFFFF_FFFF }
}

enum RecorderConnectionState: Equatable {
    case unavailable
    case disconnected
    case scanning
    case connecting
    case discovering
    case connected

    var title: String {
        switch self {
        case .unavailable: "Bluetooth недоступен"
        case .disconnected: "Не подключено"
        case .scanning: "Поиск устройства…"
        case .connecting: "Подключение…"
        case .discovering: "Настройка соединения…"
        case .connected: "Подключено"
        }
    }
}

enum RecorderCompanionError: LocalizedError {
    case bluetoothUnavailable
    case notConnected
    case noRecording
    case transferAlreadyRunning
    case transferMismatch
    case checksumMismatch
    case invalidWAV
    case disconnected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            "Включите Bluetooth и разрешите доступ к нему в настройках iPhone."
        case .notConnected:
            "Сначала подключите LLM Dict Recorder."
        case .noRecording:
            "На устройстве пока нет завершённой записи."
        case .transferAlreadyRunning:
            "Передача записи уже выполняется."
        case .transferMismatch:
            "Полученная запись имеет неверный размер. Повторите синхронизацию."
        case .checksumMismatch:
            "Проверка целостности записи не пройдена. Повторите синхронизацию."
        case .invalidWAV:
            "Устройство передало файл без корректного WAV-заголовка."
        case .disconnected:
            "Связь с устройством прервана во время передачи."
        case .timedOut:
            "Устройство слишком долго не отвечает. Повторите синхронизацию."
        }
    }
}

@MainActor
@Observable
final class RecorderCompanionService: NSObject {
    static let deviceName = "LLM Dict Recorder"

    private static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let productSignature = Data("LLMD1".utf8)

    private(set) var connectionState: RecorderConnectionState = .unavailable
    private(set) var deviceInfo: RecorderDeviceInfo?
    private(set) var transferProgress = 0.0
    private(set) var isTransferring = false
    private(set) var lastError: String?
    private(set) var lastImportedAt: Date?

    @ObservationIgnored private var centralManager: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var rxCharacteristic: CBCharacteristic?
    @ObservationIgnored private var txCharacteristic: CBCharacteristic?
    @ObservationIgnored private var parser = RecorderProtocolParser()
    @ObservationIgnored private var outputURL: URL?
    @ObservationIgnored private var outputHandle: FileHandle?
    @ObservationIgnored private var expectedSize: UInt32 = 0
    @ObservationIgnored private var receivedSize: UInt32 = 0
    @ObservationIgnored private var crc32 = RecorderCRC32()
    @ObservationIgnored private var downloadContinuation: CheckedContinuation<URL, Error>?
    @ObservationIgnored private var transferTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        lastError = nil
        guard centralManager.state == .poweredOn else {
            connectionState = .unavailable
            lastError = RecorderCompanionError.bluetoothUnavailable.localizedDescription
            return
        }

        if let peripheral, peripheral.state == .connected {
            connectionState = .connected
            requestInfo()
            return
        }

        connectionState = .scanning
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func disconnect() {
        centralManager.stopScan()
        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        } else {
            resetConnection()
        }
    }

    func requestInfo() {
        writeCommand(Data("LDI1".utf8))
    }

    func downloadLatestRecording() async throws -> URL {
        guard connectionState == .connected, rxCharacteristic != nil else {
            throw RecorderCompanionError.notConnected
        }
        guard deviceInfo?.hasRecording == true else {
            throw RecorderCompanionError.noRecording
        }
        guard downloadContinuation == nil else {
            throw RecorderCompanionError.transferAlreadyRunning
        }

        lastError = nil
        transferProgress = 0
        isTransferring = true
        parser = RecorderProtocolParser()
        expectedSize = 0
        receivedSize = 0
        crc32 = RecorderCRC32()

        return try await withCheckedThrowingContinuation { continuation in
            downloadContinuation = continuation
            var command = Data("LDG1".utf8)
            command.appendLittleEndian(UInt32(0))
            writeCommand(command)
            transferTimeoutTask?.cancel()
            transferTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard Task.isCancelled == false else { return }
                self?.failTransfer(RecorderCompanionError.timedOut)
            }
        }
    }

    func markImported() {
        lastImportedAt = .now
        lastError = nil
    }

    func report(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func writeCommand(_ data: Data) {
        guard let peripheral, let rxCharacteristic else {
            if downloadContinuation != nil {
                failTransfer(RecorderCompanionError.notConnected)
            }
            return
        }
        peripheral.writeValue(data, for: rxCharacteristic, type: .withResponse)
    }

    private func handleNotification(_ data: Data) {
        do {
            for event in try parser.consume(data) {
                try handle(event)
            }
        } catch {
            failTransfer(error)
        }
    }

    private func handle(_ event: RecorderProtocolEvent) throws {
        switch event {
        case let .info(info):
            deviceInfo = info

        case let .transferStarted(totalSize, offset):
            guard isTransferring, offset == 0, totalSize > 44 else {
                throw RecorderCompanionError.transferMismatch
            }
            if let reportedSize = deviceInfo?.wavSize, reportedSize > 0, reportedSize != totalSize {
                throw RecorderCompanionError.transferMismatch
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LLM-Dict-Recorder-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            outputURL = url
            outputHandle = try FileHandle(forWritingTo: url)
            expectedSize = totalSize

        case let .payload(data):
            guard let outputHandle else { throw RecorderCompanionError.transferMismatch }
            try outputHandle.write(contentsOf: data)
            crc32.update(with: data)
            receivedSize += UInt32(data.count)
            transferProgress = expectedSize == 0 ? 0 : min(1, Double(receivedSize) / Double(expectedSize))

        case let .transferFinished(totalSize, expectedCRC):
            guard totalSize == expectedSize, receivedSize == expectedSize else {
                throw RecorderCompanionError.transferMismatch
            }
            guard crc32.value == expectedCRC else {
                throw RecorderCompanionError.checksumMismatch
            }

            try outputHandle?.close()
            outputHandle = nil
            guard let outputURL, try Self.isValidWAV(at: outputURL) else {
                throw RecorderCompanionError.invalidWAV
            }

            isTransferring = false
            transferProgress = 1
            transferTimeoutTask?.cancel()
            transferTimeoutTask = nil
            let continuation = downloadContinuation
            downloadContinuation = nil
            continuation?.resume(returning: outputURL)
            requestInfo()
        }
    }

    private func failTransfer(_ error: Error) {
        try? outputHandle?.close()
        outputHandle = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        isTransferring = false
        transferProgress = 0
        transferTimeoutTask?.cancel()
        transferTimeoutTask = nil
        lastError = error.localizedDescription
        let continuation = downloadContinuation
        downloadContinuation = nil
        continuation?.resume(throwing: error)
    }

    private func resetConnection() {
        peripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        deviceInfo = nil
        connectionState = centralManager.state == .poweredOn ? .disconnected : .unavailable
    }

    private static func isValidWAV(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12 else { return false }
        return String(decoding: header.prefix(4), as: UTF8.self) == "RIFF"
            && String(decoding: header.suffix(4), as: UTF8.self) == "WAVE"
    }
}

extension RecorderCompanionService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if connectionState == .unavailable {
                connectionState = .disconnected
            }
        default:
            central.stopScan()
            if isTransferring {
                failTransfer(RecorderCompanionError.disconnected)
            }
            resetConnection()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data == Self.productSignature else {
            return
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .discovering
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        lastError = error?.localizedDescription ?? "Не удалось подключиться к устройству."
        resetConnection()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if isTransferring {
            failTransfer(error ?? RecorderCompanionError.disconnected)
        } else if let error {
            lastError = error.localizedDescription
        }
        resetConnection()
    }
}

extension RecorderCompanionService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastError = error.localizedDescription
            disconnect()
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            lastError = "BLE-сервис диктофона не найден."
            disconnect()
            return
        }
        peripheral.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            lastError = error.localizedDescription
            disconnect()
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.rxUUID { rxCharacteristic = characteristic }
            if characteristic.uuid == Self.txUUID { txCharacteristic = characteristic }
        }

        guard rxCharacteristic != nil, let txCharacteristic else {
            lastError = "BLE-характеристики диктофона не найдены."
            disconnect()
            return
        }
        peripheral.setNotifyValue(true, for: txCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            lastError = error.localizedDescription
            disconnect()
            return
        }
        guard characteristic.uuid == Self.txUUID, characteristic.isNotifying else { return }
        connectionState = .connected
        requestInfo()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            failTransfer(error)
            return
        }
        guard characteristic.uuid == Self.txUUID, let data = characteristic.value else { return }
        handleNotification(data)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            if isTransferring {
                failTransfer(error)
            } else {
                lastError = error.localizedDescription
            }
        }
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
