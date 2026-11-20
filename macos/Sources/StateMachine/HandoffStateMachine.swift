import Foundation
import os

public enum HandoffOwnership: String, Sendable, Equatable {
    case idle
    case macActive
    case phoneActive
    case handingOffToMac
    case handingOffToPhone
}

@MainActor
public protocol BudsControlling: AnyObject {
    var budsDisplayName: String? { get }
    var isBudsConnectedToMac: Bool { get }
    func pullBuds() async -> Bool
    func releaseBuds() async -> Bool
}

@MainActor
public protocol MediaPausing: AnyObject {
    func pauseLocalMediaIfPlaying(isPlaying: Bool)
}

@MainActor
public final class HandoffStateMachine {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "HandoffStateMachine")

    public private(set) var ownership: HandoffOwnership = .idle {
        didSet { onStateChanged?() }
    }
    public private(set) var isPhoneInCall: Bool = false {
        didSet { onStateChanged?() }
    }
    public private(set) var isAutoSwitchEnabled: Bool = true {
        didSet { onStateChanged?() }
    }

    public var onStateChanged: (() -> Void)?
    public var onFrameTransmitted: ((HandoffFrame) -> Void)?

    private let bleTransport: BLETransport
    private let budsController: BudsControlling
    private let mediaPauser: MediaPausing
    private let mediaDebounce: Duration
    private let cooldownDuration: Duration
    private let nowProvider: () -> ContinuousClock.Instant

    private var sequenceNumber: UInt16 = 0
    private var isLocalAudioPlaying = false
    private var lastHandoffCompletedAt: ContinuousClock.Instant?
    private var lastFailedPullAt: ContinuousClock.Instant?
    private var phoneReportedBudsConnected = false
    private var phoneState: PeerState = .idle
    private var debounceTask: Task<Void, Never>?

    public init(
        bleTransport: BLETransport,
        budsController: BudsControlling,
        mediaPauser: MediaPausing,
        mediaDebounce: Duration = .milliseconds(400),
        cooldownDuration: Duration = .milliseconds(2500),
        nowProvider: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.bleTransport = bleTransport
        self.budsController = budsController
        self.mediaPauser = mediaPauser
        self.mediaDebounce = mediaDebounce
        self.cooldownDuration = cooldownDuration
        self.nowProvider = nowProvider
    }

    public func setAutoSwitchEnabled(_ enabled: Bool) {
        isAutoSwitchEnabled = enabled
        if !enabled {
            cancelPendingDebounce()
        }
    }

    public func handleLocalAudioChanged(isPlaying: Bool) {
        isLocalAudioPlaying = isPlaying
        guard isPlaying else {
            cancelPendingDebounce()
            if ownership == .macActive && !budsController.isBudsConnectedToMac {
                ownership = .idle
            }
            return
        }

        guard isAutoSwitchEnabled else { return }
        guard !isPhoneInCall else {
            logger.info("Ignoring Mac audio start while phone is in call (CALL_LOCK)")
            return
        }
        guard ownership != .macActive && ownership != .handingOffToMac else { return }
        guard !isInCooldown() else {
            logger.debug("Ignoring Mac audio start during post-handoff cooldown")
            return
        }

        scheduleMacMediaClaim()
    }

    public func handleRemoteFrame(_ frame: HandoffFrame) {
        switch frame.opcode {
        case .claim:
            handleRemoteClaim(frame)
        case .released:
            if ownership == .handingOffToPhone {
                ownership = .phoneActive
                lastHandoffCompletedAt = nowProvider()
            }
        case .stateSync:
            phoneState = frame.state
            phoneReportedBudsConnected = (frame.state == .budsConnected || frame.state == .playing || frame.state == .inCall)
            isPhoneInCall = (frame.state == .inCall)
            if isPhoneInCall {
                cancelPendingDebounce()
            }
        case .heartbeatAck:
            break
        }
    }

    public func handleManualPull() {
        guard !isPhoneInCall else {
            logger.info("Blocked manual pull during active phone call")
            return
        }
        cancelPendingDebounce()
        Task { await executePullToMac(reason: .manual) }
    }

    public func handleManualRelease() {
        cancelPendingDebounce()
        Task { await executeReleaseToPhone(reason: .manual) }
    }

    public func handleMacWillSleep() {
        cancelPendingDebounce()
        if ownership == .macActive || ownership == .handingOffToMac || budsController.isBudsConnectedToMac {
            Task { await executeReleaseToPhone(reason: .none) }
        }
    }

    // MARK: - Private Transitions

    private func handleRemoteClaim(_ frame: HandoffFrame) {
        if frame.reason == .call || frame.state == .inCall {
            // Priority invariant: CALL preempts media with 0 ms debounce.
            isPhoneInCall = true
            phoneState = .inCall
            phoneReportedBudsConnected = true
            cancelPendingDebounce()
            mediaPauser.pauseLocalMediaIfPlaying(isPlaying: isLocalAudioPlaying)
            Task { await executeReleaseToPhone(reason: .call) }
            return
        }

        isPhoneInCall = false
        phoneState = frame.state
        phoneReportedBudsConnected = true

        guard isAutoSwitchEnabled else { return }
        guard !isInCooldown() else {
            logger.debug("Ignoring phone media claim during post-handoff cooldown")
            return
        }

        cancelPendingDebounce()
        mediaPauser.pauseLocalMediaIfPlaying(isPlaying: isLocalAudioPlaying)
        Task { await executeReleaseToPhone(reason: .media) }
    }

    private func scheduleMacMediaClaim() {
        cancelPendingDebounce()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.mediaDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard self.isLocalAudioPlaying,
                  self.isAutoSwitchEnabled,
                  !self.isPhoneInCall,
                  !self.isInCooldown() else {
                return
            }
            await self.executePullToMac(reason: .media)
        }
    }

    private func executePullToMac(reason: HandoffReason) async {
        // Guard: if a recent auto openConnection() failed (e.g. Buds in case), avoid spamming retries.
        if reason == .media,
           let lastFailedPullAt,
           (nowProvider() - lastFailedPullAt) < .seconds(10) {
            logger.debug("Skipping auto pull: recent openConnection() failed")
            return
        }

        ownership = .handingOffToMac
        transmit(opcode: .claim, reason: reason, state: isLocalAudioPlaying ? .playing : .idle)

        let success = await budsController.pullBuds()
        if success {
            lastFailedPullAt = nil
            ownership = .macActive
            lastHandoffCompletedAt = nowProvider()
            transmit(opcode: .stateSync, reason: .none, state: .budsConnected)
        } else {
            lastFailedPullAt = nowProvider()
            ownership = phoneReportedBudsConnected ? .phoneActive : .idle
            transmit(opcode: .stateSync, reason: .none, state: .idle)
        }
    }

    private func executeReleaseToPhone(reason: HandoffReason) async {
        ownership = .handingOffToPhone
        _ = await budsController.releaseBuds()
        ownership = .phoneActive
        lastHandoffCompletedAt = nowProvider()
        transmit(opcode: .released, reason: reason, state: .idle)
    }

    private func transmit(opcode: HandoffOpcode, reason: HandoffReason, state: PeerState) {
        sequenceNumber &+= 1
        let frame = HandoffFrame(
            opcode: opcode,
            reason: reason,
            state: state,
            seq: sequenceNumber
        )
        _ = bleTransport.sendFrame(frame)
        onFrameTransmitted?(frame)
    }

    private func isInCooldown() -> Bool {
        guard let lastHandoffCompletedAt else { return false }
        return (nowProvider() - lastHandoffCompletedAt) < cooldownDuration
    }

    private func cancelPendingDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }
}
