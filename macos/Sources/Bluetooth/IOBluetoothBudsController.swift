import Foundation
import IOBluetooth
import os

@MainActor
public final class IOBluetoothBudsController: BudsControlling {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "IOBluetoothBuds")
    private let audioMonitor: CoreAudioMonitor
    private var isOperationInFlight = false

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
        guard !isOperationInFlight else {
            logger.debug("Ignoring pullBuds(): Bluetooth operation already in flight")
            return false
        }
        guard let address = findTargetBudsDevice()?.addressString else {
            logger.warning("No paired Galaxy Buds found on this Mac")
            return false
        }

        isOperationInFlight = true
        defer { isOperationInFlight = false }

        let status = await Task.detached(priority: .userInitiated) {
            guard let device = IOBluetoothDevice(addressString: address) else {
                return kIOReturnNoDevice
            }
            return device.openConnection()
        }.value

        if status == kIOReturnSuccess {
            logger.info("IOBluetoothDevice.openConnection() succeeded")
            return true
        }
        logger.warning("IOBluetoothDevice.openConnection() returned \(status)")
        return isBudsConnectedToMac
    }

    public func releaseBuds() async -> Bool {
        guard !isOperationInFlight else {
            logger.debug("Ignoring releaseBuds(): Bluetooth operation already in flight")
            return false
        }
        guard let device = findTargetBudsDevice(), let address = device.addressString else {
            return false
        }
        guard isBudsConnectedToMac || device.isConnected() else {
            logger.debug("Skipping closeConnection(): Buds are not connected to Mac")
            return true
        }

        isOperationInFlight = true
        defer { isOperationInFlight = false }

        let status = await Task.detached(priority: .userInitiated) {
            guard let target = IOBluetoothDevice(addressString: address) else {
                return kIOReturnNoDevice
            }
            return target.closeConnection()
        }.value

        logger.info("IOBluetoothDevice.closeConnection() returned \(status)")
        return status == kIOReturnSuccess
    }

    private func findTargetBudsDevice() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var seen = Set<String>()
        for device in paired {
            let addr = (device.addressString ?? "").lowercased()
            if !addr.isEmpty && !seen.insert(addr).inserted {
                continue
            }
            let name = (device.name ?? "").lowercased()
            if name.contains("buds") || name.contains("galaxy") {
                return device
            }
        }
        return nil
    }
}
