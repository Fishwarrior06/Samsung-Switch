#!/usr/bin/env swift
//
// Phase 0 Hardware Validation Spike — IOBluetoothDevice openConnection() / closeConnection()
//
// Purpose:
//   Verify how real Galaxy Buds react to macOS IOBluetooth baseband connect/disconnect:
//   1. Flow A (Phone -> Mac): Does openConnection() pull the Buds from Samsung to Mac?
//   2. Flow B (Mac -> Phone): After closeConnection(), do the Buds auto-reconnect to Samsung
//      within 1-3s, or do they stay idle (which determines whether Android needs Shizuku)?
//
// Usage:
//   swift scripts/phase0-iobluetooth-spike.swift
//   swift scripts/phase0-iobluetooth-spike.swift --list
//   swift scripts/phase0-iobluetooth-spike.swift --name "Buds" --interactive
//   swift scripts/phase0-iobluetooth-spike.swift --name "Buds" --open
//   swift scripts/phase0-iobluetooth-spike.swift --name "Buds" --close
//

import CoreAudio
import Foundation
import IOBluetooth
import os

// MARK: - Logging & Output Helpers

private let logger = Logger(subsystem: "com.samsungswitch.phase0", category: "IOBluetoothSpike")
private let clock = ContinuousClock()

func out(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

func maskAddress(_ address: String?) -> String {
    guard let address, !address.isEmpty else { return "unknown" }
    let parts = address.split(whereSeparator: { $0 == ":" || $0 == "-" })
    guard parts.count >= 2 else { return "masked" }
    return "XX:XX:XX:XX:\(parts[parts.count - 2]):\(parts[parts.count - 1])"
}

func formatIOReturn(_ status: IOReturn) -> String {
    let hex = String(format: "0x%08X", UInt32(bitPattern: status))
    switch status {
    case kIOReturnSuccess:
        return "kIOReturnSuccess (\(hex))"
    case kIOReturnNotOpen:
        return "kIOReturnNotOpen (\(hex))"
    case kIOReturnBusy:
        return "kIOReturnBusy (\(hex))"
    case kIOReturnTimeout:
        return "kIOReturnTimeout (\(hex))"
    case kIOReturnNoDevice:
        return "kIOReturnNoDevice (\(hex))"
    case kIOReturnNotReady:
        return "kIOReturnNotReady (\(hex))"
    default:
        return "IOReturn(\(status), \(hex))"
    }
}

func formatDuration(_ duration: Duration) -> String {
    let ms = Double(duration.components.seconds) * 1000.0
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
    return String(format: "%.0f ms", ms)
}

// MARK: - CoreAudio Default Output Observer

final class CoreAudioOutputObserver: @unchecked Sendable {
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var isActive = false
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    static func currentDefaultOutputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return "Unknown (status=\(status))"
        }

        var nameCF: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let nameStatus = withUnsafeMutablePointer(to: &nameCF) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        guard nameStatus == noErr else {
            return "AudioDeviceID(\(deviceID))"
        }
        return nameCF as String
    }

    func start(startTime: ContinuousClock.Instant, onChange: @escaping @Sendable (String, Duration) -> Void) {
        stop()
        isActive = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isActive else { return }
            let elapsed = clock.now - startTime
            let currentName = Self.currentDefaultOutputDeviceName()
            onChange(currentName, elapsed)
        }
        self.listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    func stop() {
        isActive = false
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
    }

    deinit {
        stop()
    }
}

// MARK: - IOBluetooth Notification Observer

@objc final class BluetoothEventObserver: NSObject {
    private let targetAddress: String
    private let startTime: ContinuousClock.Instant
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?

    init(targetAddress: String, startTime: ContinuousClock.Instant) {
        self.targetAddress = targetAddress
        self.startTime = startTime
        super.init()
    }

    func start(for device: IOBluetoothDevice) {
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(handleConnectNotification(_:device:))
        )
        if device.isConnected() {
            registerDisconnect(for: device)
        }
    }

    func registerDisconnect(for device: IOBluetoothDevice) {
        disconnectNotification?.unregister()
        disconnectNotification = device.register(
            forDisconnectNotification: self,
            selector: #selector(handleDisconnectNotification(_:device:))
        )
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotification?.unregister()
        disconnectNotification = nil
    }

    @objc private func handleConnectNotification(
        _ notification: IOBluetoothUserNotification?,
        device: IOBluetoothDevice?
    ) {
        guard let device, device.addressString == targetAddress else { return }
        let elapsed = clock.now - startTime
        logger.info("Baseband connected at \(formatDuration(elapsed))")
        out("  [BT Event @ +\(formatDuration(elapsed))] Baseband CONNECTED -> \(device.name ?? "Unknown")")
        registerDisconnect(for: device)
    }

    @objc private func handleDisconnectNotification(
        _ notification: IOBluetoothUserNotification?,
        device: IOBluetoothDevice?
    ) {
        guard let device, device.addressString == targetAddress else { return }
        let elapsed = clock.now - startTime
        logger.info("Baseband disconnected at \(formatDuration(elapsed))")
        out("  [BT Event @ +\(formatDuration(elapsed))] Baseband DISCONNECTED -> \(device.name ?? "Unknown")")
    }

    deinit {
        stop()
    }
}

// MARK: - CLI Argument Parsing

enum ActionMode {
    case list
    case interactive
    case openOnly
    case closeOnly
}

struct Options {
    var mode: ActionMode = .interactive
    var nameFilter: String?
    var addressFilter: String?
    var showFullAddress: Bool = false
    var observeSeconds: TimeInterval = 5.0
}

func parseOptions() -> Options {
    var opts = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--list", "-l":
            opts.mode = .list
        case "--interactive", "-i":
            opts.mode = .interactive
        case "--open":
            opts.mode = .openOnly
        case "--close":
            opts.mode = .closeOnly
        case "--name", "-n":
            opts.nameFilter = args.next()
        case "--address", "-a":
            opts.addressFilter = args.next()
        case "--show-address":
            opts.showFullAddress = true
        case "--observe-seconds":
            if let raw = args.next(), let val = TimeInterval(raw), val > 0 {
                opts.observeSeconds = val
            }
        case "--help", "-h":
            out("""
            Phase 0 IOBluetooth Validation Spike

            Options:
              --list, -l               List paired Bluetooth devices and exit
              --interactive, -i        Guided Flow A (open) + Flow B (close) test (default)
              --open                   Run only openConnection() on target device
              --close                  Run only closeConnection() on target device
              --name, -n <substring>   Match paired device by name (case-insensitive)
              --address, -a <addr>     Match paired device by MAC address
              --show-address           Display unmasked MAC addresses locally
              --observe-seconds <sec>  RunLoop observation window after connect/disconnect (default: 5)
              --help, -h               Show this help
            """)
            exit(0)
        default:
            out("Unknown argument: \(arg). Use --help for usage.")
            exit(2)
        }
    }
    return opts
}

// MARK: - Device Selection

func pairedDevices() -> [IOBluetoothDevice] {
    let raw = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    var seen = Set<String>()
    var unique: [IOBluetoothDevice] = []
    for device in raw {
        let key = (device.addressString ?? "").lowercased()
        if !key.isEmpty {
            guard seen.insert(key).inserted else { continue }
        }
        unique.append(device)
    }
    return unique
}

func displayAddress(_ device: IOBluetoothDevice, showFull: Bool) -> String {
    showFull ? (device.addressString ?? "unknown") : maskAddress(device.addressString)
}

func printPairedDevices(_ devices: [IOBluetoothDevice], showFullAddress: Bool) {
    if devices.isEmpty {
        out("No paired Bluetooth devices found on this Mac.")
        out("Pair your Galaxy Buds with macOS System Settings -> Bluetooth first.")
        return
    }
    out("Paired Bluetooth devices (\(devices.count)):")
    for (idx, device) in devices.enumerated() {
        let name = device.name ?? "(Unnamed)"
        let addr = displayAddress(device, showFull: showFullAddress)
        let status = device.isConnected() ? "CONNECTED" : "disconnected"
        out("  [\(idx)] \(name) | \(addr) | \(status)")
    }
}

func selectDevice(from devices: [IOBluetoothDevice], opts: Options) -> IOBluetoothDevice? {
    if let addrFilter = opts.addressFilter?.lowercased() {
        return devices.first { ($0.addressString ?? "").lowercased() == addrFilter }
    }
    if let nameFilter = opts.nameFilter?.lowercased() {
        let matches = devices.filter { ($0.name ?? "").lowercased().contains(nameFilter) }
        if matches.count == 1 {
            return matches[0]
        }
        if matches.count > 1 {
            out("Multiple devices matched '\(opts.nameFilter ?? "")':")
            printPairedDevices(matches, showFullAddress: opts.showFullAddress)
            return promptSelection(from: matches)
        }
        out("No paired device matched '\(opts.nameFilter ?? "")'.")
        return nil
    }

    // Auto-highlight Galaxy Buds if clearly present, otherwise prompt user.
    printPairedDevices(devices, showFullAddress: opts.showFullAddress)
    if devices.isEmpty { return nil }

    let budsMatches = devices.filter {
        let lower = ($0.name ?? "").lowercased()
        return lower.contains("buds") || lower.contains("galaxy")
    }
    if budsMatches.count == 1, let candidate = budsMatches.first {
        out("\nAuto-detected candidate: \(candidate.name ?? "Unknown"). Press Enter to use it, or enter an index [0-\(devices.count - 1)]:")
        if let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            if let idx = Int(line), devices.indices.contains(idx) {
                return devices[idx]
            }
            out("Invalid selection.")
            return nil
        }
        return candidate
    }

    return promptSelection(from: devices)
}

func promptSelection(from devices: [IOBluetoothDevice]) -> IOBluetoothDevice? {
    out("\nSelect device index [0-\(devices.count - 1)]:")
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          let idx = Int(line),
          devices.indices.contains(idx) else {
        out("Invalid selection.")
        return nil
    }
    return devices[idx]
}

// MARK: - Spike Actions

func pumpRunLoop(seconds: TimeInterval) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: deadline)
    }
}

func runOpenTest(device: IOBluetoothDevice, observeSeconds: TimeInterval) {
    let t0 = clock.now
    let audioObserver = CoreAudioOutputObserver()
    let btObserver = BluetoothEventObserver(targetAddress: device.addressString ?? "", startTime: t0)

    btObserver.start(for: device)
    audioObserver.start(startTime: t0) { newDevice, elapsed in
        out("  [CoreAudio @ +\(formatDuration(elapsed))] Default output -> \(newDevice)")
    }

    out("\n--- Flow A: Calling openConnection() ---")
    out("  Before: isConnected=\(device.isConnected()), defaultOutput='\(CoreAudioOutputObserver.currentDefaultOutputDeviceName())'")

    let result = device.openConnection()
    let callElapsed = clock.now - t0
    logger.info("openConnection() returned \(formatIOReturn(result)) in \(formatDuration(callElapsed))")
    out("  openConnection() returned \(formatIOReturn(result)) in \(formatDuration(callElapsed))")
    out("  Immediate after: isConnected=\(device.isConnected()), defaultOutput='\(CoreAudioOutputObserver.currentDefaultOutputDeviceName())'")

    out("  Observing system callbacks for \(Int(observeSeconds))s (A2DP profile + CoreAudio switch)...")
    pumpRunLoop(seconds: observeSeconds)

    out("  After \(Int(observeSeconds))s: isConnected=\(device.isConnected()), defaultOutput='\(CoreAudioOutputObserver.currentDefaultOutputDeviceName())'")
    audioObserver.stop()
    btObserver.stop()
}

func runCloseTest(device: IOBluetoothDevice, observeSeconds: TimeInterval) {
    let t0 = clock.now
    let audioObserver = CoreAudioOutputObserver()
    let btObserver = BluetoothEventObserver(targetAddress: device.addressString ?? "", startTime: t0)

    btObserver.start(for: device)
    audioObserver.start(startTime: t0) { newDevice, elapsed in
        out("  [CoreAudio @ +\(formatDuration(elapsed))] Default output -> \(newDevice)")
    }

    out("\n--- Flow B: Calling closeConnection() ---")
    out("  Before: isConnected=\(device.isConnected()), defaultOutput='\(CoreAudioOutputObserver.currentDefaultOutputDeviceName())'")

    let result = device.closeConnection()
    let callElapsed = clock.now - t0
    logger.info("closeConnection() returned \(formatIOReturn(result)) in \(formatDuration(callElapsed))")
    out("  closeConnection() returned \(formatIOReturn(result)) in \(formatDuration(callElapsed))")
    out("  Immediate after: isConnected=\(device.isConnected()), defaultOutput='\(CoreAudioOutputObserver.currentDefaultOutputDeviceName())'")

    out("  Observing system callbacks for \(Int(observeSeconds))s...")
    pumpRunLoop(seconds: observeSeconds)

    out("  After \(Int(observeSeconds))s: isConnected=\(device.isConnected()), defaultOutput='\(CoreAudioOutputObserver.currentDefaultOutputDeviceName())'")
    audioObserver.stop()
    btObserver.stop()
}

// MARK: - Main Entry Point

let opts = parseOptions()
let devices = pairedDevices()

if opts.mode == .list {
    printPairedDevices(devices, showFullAddress: opts.showFullAddress)
    exit(0)
}

guard let target = selectDevice(from: devices, opts: opts) else {
    exit(1)
}

let targetName = target.name ?? "Unknown"
out("\nTarget device: \(targetName) (\(displayAddress(target, showFull: opts.showFullAddress)))")
out("Current Mac default audio output: \(CoreAudioOutputObserver.currentDefaultOutputDeviceName())")

switch opts.mode {
case .list:
    break
case .openOnly:
    runOpenTest(device: target, observeSeconds: opts.observeSeconds)
case .closeOnly:
    runCloseTest(device: target, observeSeconds: opts.observeSeconds)
case .interactive:
    out("""

    === Phase 0 Step 1: Phone -> Mac (openConnection) ===
    1. Put your Galaxy Buds in your ears.
    2. Connect them to your Samsung phone and start playing audio (e.g. Spotify/YouTube).
    3. Ensure 'Seamless earbud connection' is enabled in Galaxy Wearable.
    4. Press Enter here to call IOBluetoothDevice.openConnection() from your Mac...
    """)
    _ = readLine()
    runOpenTest(device: target, observeSeconds: opts.observeSeconds)

    out("""

    === Phase 0 Step 2: Mac -> Phone (closeConnection) ===
    1. Confirm audio/connection is now on the Mac.
    2. Watch your Samsung phone's Bluetooth/Quick Panel closely.
    3. Press Enter here to call IOBluetoothDevice.closeConnection() from your Mac...
    """)
    _ = readLine()
    runCloseTest(device: target, observeSeconds: opts.observeSeconds)

    out("""

    === Phase 0 Observation Question ===
    After closeConnection() finished:
      - Did your Galaxy Buds AUTO-RECONNECT to your Samsung phone within 1-3 seconds?
        -> YES: Android does NOT need Shizuku! Zero-privilege auto-reconnect works.
        -> NO (they stayed idle/disconnected): Android WILL need Shizuku (BudsConnector) to trigger A2DP reconnect.
    """)
}
