import CoreAudio
import Foundation
import os

@MainActor
public protocol AudioMonitoring: AnyObject {
    var isDefaultOutputRunning: Bool { get }
    var defaultOutputDeviceName: String { get }
    var onRunningChanged: ((Bool) -> Void)? { get set }
    var onPlaybackActivityDetected: (() -> Void)? { get set }
    var onOutputDeviceChanged: ((String) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
public final class CoreAudioMonitor: AudioMonitoring {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "CoreAudioMonitor")

    public private(set) var isDefaultOutputRunning: Bool = false
    public private(set) var defaultOutputDeviceName: String = "Unknown"
    public var onRunningChanged: ((Bool) -> Void)?
    public var onPlaybackActivityDetected: (() -> Void)?
    public var onOutputDeviceChanged: ((String) -> Void)?

    private var isMonitoring = false
    private var observedDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var isRunningBlock: AudioObjectPropertyListenerBlock?
    private var processListBlock: AudioObjectPropertyListenerBlock?
    private var processListenerBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var runningOutputProcessIDs = Set<AudioObjectID>()
    private var lastEffectiveRunning = false

    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var isRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    public init() {}

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring else { return }
                self.refreshDefaultOutputDevice()
            }
        }
        defaultDeviceBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            block
        )

        refreshDefaultOutputDevice()
        startProcessMonitoringIfAvailable()
        logger.info("CoreAudioMonitor started (output='\(self.defaultOutputDeviceName, privacy: .public)')")
    }

    public func stop() {
        isMonitoring = false
        removeDeviceRunningListener()
        stopProcessMonitoringIfAvailable()
        if let block = defaultDeviceBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                DispatchQueue.main,
                block
            )
            defaultDeviceBlock = nil
        }
    }

    public func isBudsActiveOutput(matching nameSubstrings: [String] = ["buds", "galaxy"]) -> Bool {
        let lower = defaultOutputDeviceName.lowercased()
        return nameSubstrings.contains { lower.contains($0.lowercased()) }
    }

    private func refreshDefaultOutputDevice() {
        let deviceID = Self.readDefaultOutputDeviceID()
        let name = Self.readDeviceName(deviceID)
        if name != defaultOutputDeviceName {
            defaultOutputDeviceName = name
            logger.info("CoreAudio default output changed: '\(name, privacy: .public)'")
            onOutputDeviceChanged?(name)
        }

        if deviceID != observedDeviceID {
            removeDeviceRunningListener()
            observedDeviceID = deviceID
            installDeviceRunningListener(for: deviceID)
        }
        refreshRunningState()
    }

    private func installDeviceRunningListener(for deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring else { return }
                self.refreshRunningState()
            }
        }
        isRunningBlock = block
        AudioObjectAddPropertyListenerBlock(deviceID, &isRunningAddress, DispatchQueue.main, block)
    }

    private func removeDeviceRunningListener() {
        guard let block = isRunningBlock else { return }
        if observedDeviceID != kAudioObjectUnknown &&
            AudioObjectHasProperty(observedDeviceID, &isRunningAddress) {
            AudioObjectRemovePropertyListenerBlock(observedDeviceID, &isRunningAddress, DispatchQueue.main, block)
        }
        isRunningBlock = nil
    }

    private func refreshRunningState() {
        isDefaultOutputRunning = Self.readIsRunningSomewhere(observedDeviceID)
        emitEffectiveRunningState(newlyStartedProcess: false)
    }

    private func emitEffectiveRunningState(newlyStartedProcess: Bool) {
        let effectiveRunning = isDefaultOutputRunning || !runningOutputProcessIDs.isEmpty
        if effectiveRunning != lastEffectiveRunning {
            lastEffectiveRunning = effectiveRunning
            logger.info(
                "CoreAudio playback state changed: running=\(effectiveRunning) (device=\(self.isDefaultOutputRunning), activeProcs=\(self.runningOutputProcessIDs.count))"
            )
            onRunningChanged?(effectiveRunning)
        } else if newlyStartedProcess && effectiveRunning {
            logger.info(
                "CoreAudio detected new active audio output process (activeProcs=\(self.runningOutputProcessIDs.count))"
            )
            onPlaybackActivityDetected?()
        }
    }

    private func startProcessMonitoringIfAvailable() {
        guard #available(macOS 14.2, *) else { return }
        var addr = Self.makeProcessListAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring else { return }
                self.refreshProcessList()
            }
        }
        processListBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        refreshProcessList()
    }

    private func stopProcessMonitoringIfAvailable() {
        guard #available(macOS 14.2, *) else { return }
        if let block = processListBlock {
            var addr = Self.makeProcessListAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                block
            )
            processListBlock = nil
        }
        var procAddr = Self.makeProcessRunningAddress()
        for (procID, block) in processListenerBlocks {
            AudioObjectRemovePropertyListenerBlock(procID, &procAddr, DispatchQueue.main, block)
        }
        processListenerBlocks.removeAll()
        runningOutputProcessIDs.removeAll()
    }

    @available(macOS 14.2, *)
    private func refreshProcessList() {
        let currentIDs = Set(Self.readProcessObjectList())
        let existingIDs = Set(processListenerBlocks.keys)

        var procAddr = Self.makeProcessRunningAddress()
        for removedID in existingIDs.subtracting(currentIDs) {
            if let block = processListenerBlocks.removeValue(forKey: removedID),
               AudioObjectHasProperty(removedID, &procAddr) {
                AudioObjectRemovePropertyListenerBlock(removedID, &procAddr, DispatchQueue.main, block)
            }
            runningOutputProcessIDs.remove(removedID)
        }

        for addedID in currentIDs.subtracting(existingIDs) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.isMonitoring else { return }
                    self.refreshProcessRunningStates()
                }
            }
            processListenerBlocks[addedID] = block
            AudioObjectAddPropertyListenerBlock(addedID, &procAddr, DispatchQueue.main, block)
        }

        refreshProcessRunningStates()
    }

    @available(macOS 14.2, *)
    private func refreshProcessRunningStates() {
        var newRunning = Set<AudioObjectID>()
        for procID in processListenerBlocks.keys where Self.readProcessIsRunningOutput(procID) {
            newRunning.insert(procID)
        }
        let newlyStarted = !newRunning.subtracting(runningOutputProcessIDs).isEmpty
        runningOutputProcessIDs = newRunning
        emitEffectiveRunningState(newlyStartedProcess: newlyStarted)
    }

    @available(macOS 14.2, *)
    private static func makeProcessListAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    @available(macOS 14.2, *)
    private static func makeProcessRunningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    @available(macOS 14.2, *)
    private static func readProcessObjectList() -> [AudioObjectID] {
        var addr = makeProcessListAddress()
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &ids
        )
        return dataStatus == noErr ? ids : []
    }

    @available(macOS 14.2, *)
    private static func readProcessIsRunningOutput(_ procID: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = makeProcessRunningAddress()
        let status = AudioObjectGetPropertyData(procID, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private static func readDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
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
        return status == noErr ? deviceID : AudioDeviceID(kAudioObjectUnknown)
    }

    private static func readDeviceName(_ deviceID: AudioDeviceID) -> String {
        guard deviceID != kAudioObjectUnknown else { return "Unknown" }
        var nameCF: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &nameCF) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? (nameCF as String) : "AudioDevice(\(deviceID))"
    }

    private static func readIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }
}
