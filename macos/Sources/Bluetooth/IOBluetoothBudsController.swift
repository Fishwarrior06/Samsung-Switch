import Foundation
import IOBluetooth
import os

@MainActor
public final class IOBluetoothBudsController: BudsControlling {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "IOBluetoothBuds")
    private let audioMonitor: CoreAudioMonitor
    private var isOperationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    private static let pageTimeoutSlots: BluetoothHCIPageTimeout = 9600 // 9600 * 0.625 ms = 6.0 s

    public init(audioMonitor: CoreAudioMonitor) {
        self.audioMonitor = audioMonitor
    }

    public var budsDisplayName: String? {
        findTargetBudsDevice()?.name
    }

    public var isBudsConnectedToMac: Bool {
        // Phase 0 finding: IOBluetoothDevice.isConnected() can return false while CoreAudio
        // has the Galaxy Buds active as the default output device.
        if audioMonitor.isBudsActiveOutput() {
            return true
        }
        return findTargetBudsDevice()?.isConnected() ?? false
    }

    public func pullBuds() async -> Bool {
        await acquireOperationTurn()
        defer { releaseOperationTurn() }

        guard !Task.isCancelled else {
            logger.debug("Cancelled pullBuds() before opening connection")
            return false
        }
        guard let address = findTargetBudsDevice()?.addressString else {
            logger.warning("No paired Galaxy Buds found on this Mac")
            return false
        }

        let firstStatus = await attemptOpenConnection(address: address)
        if firstStatus == kIOReturnSuccess || isBudsConnectedToMac {
            logger.info("IOBluetoothDevice.openConnection() succeeded")
            return true
        }

        guard !Task.isCancelled else {
            logger.debug("Cancelled pullBuds() before retry")
            return false
        }

        logger.warning("First openConnection() attempt returned \(firstStatus); retrying after 300 ms")
        try? await Task.sleep(for: .milliseconds(300))

        guard !Task.isCancelled else {
            logger.debug("Cancelled pullBuds() after retry backoff")
            return false
        }

        let retryStatus = await attemptOpenConnection(address: address)
        if retryStatus == kIOReturnSuccess || isBudsConnectedToMac {
            logger.info("IOBluetoothDevice.openConnection() retry succeeded")
            return true
        }

        logger.error("IOBluetoothDevice.openConnection() failed after retry: \(retryStatus)")
        return false
    }

    public func releaseBuds() async -> Bool {
        await acquireOperationTurn()
        defer { releaseOperationTurn() }

        guard let device = findTargetBudsDevice(), let address = device.addressString else {
            return !isBudsConnectedToMac
        }
        guard isBudsConnectedToMac || device.isConnected() else {
            logger.debug("Skipping closeConnection(): Buds are not connected to Mac")
            return true
        }

        let status = await Task.detached(priority: .userInitiated) {
            guard let target = IOBluetoothDevice(addressString: address) else {
                return kIOReturnNoDevice
            }
            return target.closeConnection()
        }.value

        logger.info("IOBluetoothDevice.closeConnection() returned \(status)")
        return status == kIOReturnSuccess || !isBudsConnectedToMac
    }

    private func acquireOperationTurn() async {
        if !isOperationInFlight {
            isOperationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperationTurn() {
        if operationWaiters.isEmpty {
            isOperationInFlight = false
        } else {
            let next = operationWaiters.removeFirst()
            next.resume()
        }
    }

    private func attemptOpenConnection(address: String) async -> IOReturn {
        let timeout = Self.pageTimeoutSlots
        return await Task.detached(priority: .userInitiated) {
            guard let device = IOBluetoothDevice(addressString: address) else {
                return kIOReturnNoDevice
            }
            return device.openConnection(nil, withPageTimeout: timeout, authenticationRequired: false)
        }.value
    }

    private func findTargetBudsDevice() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var seen = Set<String>()
        var unique: [IOBluetoothDevice] = []
        for device in paired {
            let addr = (device.addressString ?? "").lowercased()
            if !addr.isEmpty && !seen.insert(addr).inserted {
                continue
            }
            unique.append(device)
        }

        if let budsDevice = unique.first(where: { ($0.name ?? "").lowercased().contains("buds") }) {
            return budsDevice
        }
        return unique.first(where: { ($0.name ?? "").lowercased().contains("galaxy") })
    }
}
