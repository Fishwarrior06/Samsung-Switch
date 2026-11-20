import CoreBluetooth
import Foundation
import os

public enum BLELinkStatus: Equatable, Sendable {
    case starting
    case bluetoothOff
    case unauthorized
    case unsupported
    case advertising
    case pausedForSleep
    case connected(subscriberCount: Int)
    case error(String)

    public var displayText: String {
        switch self {
        case .starting:
            return "Starting BLE..."
        case .bluetoothOff:
            return "Bluetooth Off"
        case .unauthorized:
            return "Bluetooth Unauthorized"
        case .unsupported:
            return "BLE Peripheral Unsupported"
        case .advertising:
            return "Advertising (Waiting for Phone)"
        case .pausedForSleep:
            return "Paused (Mac Sleeping)"
        case .connected(let count):
            return "Connected (\(count) phone\(count == 1 ? "" : "s"))"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

@MainActor
public protocol BLETransport: AnyObject {
    var status: BLELinkStatus { get }
    var onStatusChanged: ((BLELinkStatus) -> Void)? { get set }
    var onPeerSubscribed: (() -> Void)? { get set }
    var onFrameReceived: ((HandoffFrame) -> Void)? { get set }

    func start()
    func stop()
    func restartAdvertising()
    func pauseForSleep()
    func resumeAfterWake()
    @discardableResult
    func sendFrame(_ frame: HandoffFrame) -> Bool
}

@MainActor
public final class BLEGattServer: NSObject, BLETransport {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "BLEGattServer")

    public private(set) var status: BLELinkStatus = .starting {
        didSet {
            if status != oldValue {
                onStatusChanged?(status)
            }
        }
    }

    public var onStatusChanged: ((BLELinkStatus) -> Void)?
    public var onPeerSubscribed: (() -> Void)?
    public var onFrameReceived: ((HandoffFrame) -> Void)?

    private let serviceUUID = CBUUID(string: ProtocolConstants.serviceUUIDString)
    private let txToMacUUID = CBUUID(string: ProtocolConstants.txToMacUUIDString)
    private let txToPhoneUUID = CBUUID(string: ProtocolConstants.txToPhoneUUIDString)

    private var peripheralManager: CBPeripheralManager?
    private var txToMacCharacteristic: CBMutableCharacteristic?
    private var txToPhoneCharacteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var isSleeping = false

    private var subscribedCentralIDs = Set<UUID>()
    private var pendingOutboundFrames: [HandoffFrame] = []
    private var latestOutboundFrame = HandoffFrame(
        opcode: .stateSync,
        reason: .none,
        state: .idle,
        seq: 0
    )

    public override init() {
        super.init()
    }

    public func start() {
        guard peripheralManager == nil else {
            evaluateStateAndStartIfReady()
            return
        }
        status = .starting
        let options: [String: Any] = [
            CBPeripheralManagerOptionShowPowerAlertKey: true
        ]
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main, options: options)
    }

    public func stop() {
        guard let peripheralManager else { return }
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        serviceAdded = false
        subscribedCentralIDs.removeAll()
        pendingOutboundFrames.removeAll()
        status = .starting
    }

    public func restartAdvertising() {
        guard let peripheralManager else {
            start()
            return
        }
        peripheralManager.stopAdvertising()
        isSleeping = false
        evaluateStateAndStartIfReady()
    }

    public func pauseForSleep() {
        isSleeping = true
        peripheralManager?.stopAdvertising()
        status = .pausedForSleep
        logger.info("Paused BLE advertising for Mac sleep")
    }

    public func resumeAfterWake() {
        isSleeping = false
        evaluateStateAndStartIfReady()
        logger.info("Resumed BLE advertising after Mac wake")
    }

    @discardableResult
    public func sendFrame(_ frame: HandoffFrame) -> Bool {
        latestOutboundFrame = frame
        guard let peripheralManager, let txToPhoneCharacteristic else {
            logger.warning("Cannot notify frame before GATT service is initialized")
            return false
        }
        guard !subscribedCentralIDs.isEmpty else {
            logger.debug("Stored frame for read; no subscribed centrals yet: \(frame.summary, privacy: .public)")
            return false
        }

        let sent = peripheralManager.updateValue(
            frame.encode(),
            for: txToPhoneCharacteristic,
            onSubscribedCentrals: nil
        )
        if sent {
            logger.info("Notified TX_TO_PHONE: \(frame.summary, privacy: .public)")
        } else {
            pendingOutboundFrames.append(frame)
            logger.debug("BLE TX queue full, queued frame seq=\(frame.seq)")
        }
        return sent
    }

    private func evaluateStateAndStartIfReady() {
        guard let peripheralManager else { return }
        guard !isSleeping else {
            status = .pausedForSleep
            return
        }

        switch peripheralManager.state {
        case .poweredOn:
            installServiceIfNeeded()
            if serviceAdded && !peripheralManager.isAdvertising {
                let advertisement: [String: Any] = [
                    CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
                    CBAdvertisementDataLocalNameKey: ProtocolConstants.localDeviceName
                ]
                peripheralManager.startAdvertising(advertisement)
                logger.info("Started BLE advertising with service UUID \(self.serviceUUID.uuidString, privacy: .public)")
            }
            updateConnectionStatus()
        case .poweredOff:
            serviceAdded = false
            subscribedCentralIDs.removeAll()
            pendingOutboundFrames.removeAll()
            status = .bluetoothOff
        case .unauthorized:
            status = .unauthorized
        case .unsupported:
            status = .unsupported
        case .resetting, .unknown:
            status = .starting
        @unknown default:
            status = .starting
        }
    }

    private func installServiceIfNeeded() {
        guard !serviceAdded, let peripheralManager else { return }

        let txToMac = CBMutableCharacteristic(
            type: txToMacUUID,
            properties: [.write],
            value: nil,
            permissions: [.writeEncryptionRequired]
        )
        let txToPhone = CBMutableCharacteristic(
            type: txToPhoneUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readEncryptionRequired]
        )

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [txToMac, txToPhone]

        txToMacCharacteristic = txToMac
        txToPhoneCharacteristic = txToPhone
        peripheralManager.add(service)
    }

    private func updateConnectionStatus() {
        if !subscribedCentralIDs.isEmpty {
            status = .connected(subscriberCount: subscribedCentralIDs.count)
        } else if peripheralManager?.state == .poweredOn {
            status = isSleeping ? .pausedForSleep : .advertising
        }
    }

    private func flushPendingOutboundFrames() {
        guard let peripheralManager, let txToPhoneCharacteristic else { return }
        while !pendingOutboundFrames.isEmpty {
            let nextFrame = pendingOutboundFrames[0]
            let sent = peripheralManager.updateValue(
                nextFrame.encode(),
                for: txToPhoneCharacteristic,
                onSubscribedCentrals: nil
            )
            if sent {
                pendingOutboundFrames.removeFirst()
                logger.info("Flushed queued TX_TO_PHONE: \(nextFrame.summary, privacy: .public)")
            } else {
                break
            }
        }
    }
    private func buildReadResponse(for uuidString: String, offset: Int) -> (CBATTError.Code, Data?) {
        guard uuidString.caseInsensitiveCompare(ProtocolConstants.txToPhoneUUIDString) == .orderedSame else {
            return (.attributeNotFound, nil)
        }
        let payload = latestOutboundFrame.encode()
        guard offset <= payload.count else {
            return (.invalidOffset, nil)
        }
        logger.debug("Served encrypted read on TX_TO_PHONE: \(self.latestOutboundFrame.summary, privacy: .public)")
        return (.success, payload.subdata(in: offset..<payload.count))
    }

    private func handleWritePayloads(_ payloads: [(uuidString: String, value: Data?)]) -> CBATTError.Code {
        for item in payloads {
            guard item.uuidString.caseInsensitiveCompare(ProtocolConstants.txToMacUUIDString) == .orderedSame else {
                return .attributeNotFound
            }
            guard let value = item.value else {
                return .invalidAttributeValueLength
            }
            do {
                let frame = try HandoffFrame.decode(value)
                logger.info("Received TX_TO_MAC: \(frame.summary, privacy: .public)")
                onFrameReceived?(frame)
            } catch {
                logger.warning("Rejected invalid TX_TO_MAC frame (\(value.count) bytes)")
                return .invalidAttributeValueLength
            }
        }
        return .success
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEGattServer: CBPeripheralManagerDelegate {
    nonisolated public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let stateRaw = peripheral.state.rawValue
        MainActor.assumeIsolated {
            logger.info("CBPeripheralManager state updated: \(stateRaw)")
            evaluateStateAndStartIfReady()
        }
    }

    nonisolated public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        let serviceUUIDString = service.uuid.uuidString
        let errorMessage = error?.localizedDescription
        MainActor.assumeIsolated {
            if let errorMessage {
                logger.error("Failed to add GATT service: \(errorMessage, privacy: .public)")
                status = .error(errorMessage)
                return
            }
            serviceAdded = true
            logger.info("GATT service added: \(serviceUUIDString, privacy: .public)")
            evaluateStateAndStartIfReady()
        }
    }

    nonisolated public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        let errorMessage = error?.localizedDescription
        MainActor.assumeIsolated {
            if let errorMessage {
                logger.error("Failed to start BLE advertising: \(errorMessage, privacy: .public)")
                status = .error(errorMessage)
                return
            }
            updateConnectionStatus()
        }
    }

    nonisolated public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        let charUUIDString = characteristic.uuid.uuidString
        let centralID = central.identifier
        MainActor.assumeIsolated {
            guard charUUIDString.caseInsensitiveCompare(ProtocolConstants.txToPhoneUUIDString) == .orderedSame else {
                return
            }
            pendingOutboundFrames.removeAll()
            subscribedCentralIDs.insert(centralID)
            updateConnectionStatus()
            logger.info("Phone subscribed to TX_TO_PHONE (subscribers=\(self.subscribedCentralIDs.count))")
            onPeerSubscribed?()
        }
    }

    nonisolated public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let charUUIDString = characteristic.uuid.uuidString
        let centralID = central.identifier
        MainActor.assumeIsolated {
            guard charUUIDString.caseInsensitiveCompare(ProtocolConstants.txToPhoneUUIDString) == .orderedSame else {
                return
            }
            subscribedCentralIDs.remove(centralID)
            if subscribedCentralIDs.isEmpty {
                pendingOutboundFrames.removeAll()
            }
            updateConnectionStatus()
            logger.info("Phone unsubscribed from TX_TO_PHONE (subscribers=\(self.subscribedCentralIDs.count))")
        }
    }

    nonisolated public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        let charUUIDString = request.characteristic.uuid.uuidString
        let offset = request.offset
        let (result, data) = MainActor.assumeIsolated {
            buildReadResponse(for: charUUIDString, offset: offset)
        }
        request.value = data
        peripheral.respond(to: request, withResult: result)
    }

    nonisolated public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        guard let firstRequest = requests.first else { return }
        let payloads = requests.map { (uuidString: $0.characteristic.uuid.uuidString, value: $0.value) }
        let result = MainActor.assumeIsolated {
            handleWritePayloads(payloads)
        }
        peripheral.respond(to: firstRequest, withResult: result)
    }

    nonisolated public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            flushPendingOutboundFrames()
        }
    }
}
