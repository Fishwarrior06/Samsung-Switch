import Foundation
import os

public enum HandoffOwnership: String, Sendable, Equatable {
    case idle
    case macActive
    case phoneActive
    case handingOffToMac
    case handingOffToPhone
}

public enum HandoffDestination: String, Sendable, Equatable {
    case mac
    case phone
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
    public var onHandoffCompleted: ((HandoffDestination, HandoffReason) -> Void)?

    private let bleTransport: BLETransport
    private let budsController: BudsControlling
    private let mediaPauser: MediaPausing
    private let mediaDebounce: Duration
    private let cooldownDuration: Duration
    private let peerReleaseWaitTimeout: Duration
    private let nowProvider: () -> ContinuousClock.Instant

    private var sequenceNumber: UInt16 = 0
    private var isLocalAudioPlaying = false
    private var lastHandoffCompletedAt: ContinuousClock.Instant?
    private var lastBudsDisconnectedAt: ContinuousClock.Instant?
    private var lastFailedPullAt: ContinuousClock.Instant?
    private var phoneReportedBudsConnected = false
    private var phoneState: PeerState = .idle
    private var debounceTask: Task<Void, Never>?
    private var activeTransitionTask: Task<Void, Never>?
    private var transitionGeneration: UInt64 = 0
    private var pendingPeerReleaseContinuation: CheckedContinuation<Void, Never>?

    public init(
        bleTransport: BLETransport,
        budsController: BudsControlling,
        mediaPauser: MediaPausing,
        mediaDebounce: Duration = .milliseconds(400),
        cooldownDuration: Duration = .milliseconds(2500),
        peerReleaseWaitTimeout: Duration = .milliseconds(600),
        nowProvider: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.bleTransport = bleTransport
        self.budsController = budsController
        self.mediaPauser = mediaPauser
        self.mediaDebounce = mediaDebounce
        self.cooldownDuration = cooldownDuration
        self.peerReleaseWaitTimeout = peerReleaseWaitTimeout
        self.nowProvider = nowProvider
    }

    public func setAutoSwitchEnabled(_ enabled: Bool) {
        isAutoSwitchEnabled = enabled
        if !enabled {
            cancelPendingDebounce()
        }
    }

    public func syncInitialBudsConnection(connectedToMac: Bool) {
        ownership = connectedToMac ? .macActive : .idle
    }

    public func handleBudsOutputChanged(connectedToMac: Bool) {
        if connectedToMac {
            if ownership != .macActive &&
                ownership != .handingOffToMac &&
                ownership != .handingOffToPhone {
                ownership = .macActive
                transmit(opcode: .stateSync, reason: .manual, state: .budsConnected)
                onHandoffCompleted?(.mac, .manual)
            }
        } else {
            cancelPendingDebounce()
            lastBudsDisconnectedAt = nowProvider()
            if ownership == .macActive {
                ownership = .idle
                transmit(opcode: .stateSync, reason: .none, state: .idle)
            }
        }
    }

    public func handleMacDidWake() {
        guard ownership != .handingOffToMac && ownership != .handingOffToPhone else { return }
        if budsController.isBudsConnectedToMac {
            if ownership != .macActive {
                ownership = .macActive
                transmit(opcode: .stateSync, reason: .none, state: .budsConnected)
            }
        } else if ownership == .macActive {
            ownership = .idle
            transmit(opcode: .stateSync, reason: .none, state: .idle)
        }
    }

    public func handlePeerConnected() {
        guard ownership != .handingOffToMac && ownership != .handingOffToPhone else { return }
        if budsController.isBudsConnectedToMac {
            ownership = .macActive
            transmit(opcode: .stateSync, reason: .none, state: .budsConnected)
        } else {
            if ownership == .macActive {
                ownership = .idle
            }
            transmit(opcode: .stateSync, reason: .none, state: .idle)
        }
    }

    public func handleLocalAudioActivityDetected() {
        handleLocalAudioChanged(isPlaying: true)
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
        guard case .connected = bleTransport.status else {
            logger.debug("Ignoring auto Mac audio pull: phone BLE link not connected")
            return
        }
        guard ownership != .macActive && ownership != .handingOffToMac else { return }
        guard !isInCooldown() && !isInPostDisconnectGrace() else {
            logger.debug("Ignoring Mac audio bounce during post-handoff/disconnect cooldown")
            return
        }

        scheduleMacMediaClaim(after: mediaDebounce)
    }

    public func handleRemoteFrame(_ frame: HandoffFrame) {
        switch frame.opcode {
        case .claim:
            handleRemoteClaim(frame)
        case .released:
            if ownership == .handingOffToMac {
                resumePendingPeerRelease()
            } else {
                phoneReportedBudsConnected = false
                if ownership == .phoneActive {
                    ownership = budsController.isBudsConnectedToMac ? .macActive : .idle
                }
            }
        case .stateSync:
            phoneState = frame.state
            phoneReportedBudsConnected = (frame.state == .budsConnected || frame.state == .playing || frame.state == .inCall)
            isPhoneInCall = (frame.state == .inCall)
            if isPhoneInCall {
                cancelPendingDebounce()
            }
            if ownership != .handingOffToMac && ownership != .handingOffToPhone {
                if budsController.isBudsConnectedToMac {
                    if ownership != .macActive {
                        ownership = .macActive
                        transmit(opcode: .stateSync, reason: .none, state: .budsConnected)
                    }
                } else if frame.state == .budsConnected || frame.state == .inCall {
                    ownership = .phoneActive
                } else if frame.state == .idle && ownership == .phoneActive {
                    ownership = .idle
                }
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
        startTransition { machine, generation in
            await machine.executePullToMac(reason: .manual, generation: generation)
        }
    }

    public func handleManualRelease() {
        startTransition { machine, generation in
            await machine.executeReleaseToPhone(reason: .manual, generation: generation)
        }
    }

    public func handleMacWillSleep() {
        cancelPendingDebounce()
        if ownership == .macActive || ownership == .handingOffToMac || budsController.isBudsConnectedToMac {
            startTransition { machine, generation in
                await machine.executeReleaseToPhone(reason: .none, generation: generation)
            }
        }
    }

    // MARK: - Private Transitions

    private func startTransition(_ body: @escaping @MainActor (HandoffStateMachine, UInt64) async -> Void) {
        cancelPendingDebounce()
        resumePendingPeerRelease()
        activeTransitionTask?.cancel()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        activeTransitionTask = Task { [weak self] in
            guard let self else { return }
            await body(self, generation)
        }
    }

    private func handleRemoteClaim(_ frame: HandoffFrame) {
        if frame.reason == .call || frame.state == .inCall {
            // Priority invariant: CALL preempts media with 0 ms debounce.
            isPhoneInCall = true
            phoneState = .inCall
            phoneReportedBudsConnected = true
            cancelPendingDebounce()
            mediaPauser.pauseLocalMediaIfPlaying(isPlaying: isLocalAudioPlaying)
            startTransition { machine, generation in
                await machine.executeReleaseToPhone(reason: .call, generation: generation)
            }
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
        startTransition { machine, generation in
            await machine.executeReleaseToPhone(reason: .media, generation: generation)
        }
    }

    private func scheduleMacMediaClaim(after delay: Duration) {
        cancelPendingDebounce()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.debounceTask = nil
            guard self.isLocalAudioPlaying,
                  self.isAutoSwitchEnabled,
                  !self.isPhoneInCall,
                  !self.isInCooldown() else {
                return
            }
            self.startTransition { machine, generation in
                await machine.executePullToMac(reason: .media, generation: generation)
            }
        }
    }

    private func executePullToMac(reason: HandoffReason, generation: UInt64) async {
        defer {
            if generation == transitionGeneration {
                activeTransitionTask = nil
            }
        }
        guard !Task.isCancelled && generation == transitionGeneration else { return }

        // Guard: if a recent auto openConnection() failed (e.g. Buds in case), avoid spamming retries.
        if reason == .media,
           let lastFailedPullAt,
           (nowProvider() - lastFailedPullAt) < .seconds(10) {
            logger.debug("Skipping auto pull: recent openConnection() failed")
            return
        }

        ownership = .handingOffToMac
        transmit(opcode: .claim, reason: reason, state: isLocalAudioPlaying ? .playing : .idle)

        if case .connected = bleTransport.status, peerReleaseWaitTimeout > .zero {
            await waitForPeerReleaseOrTimeout()
        }
        guard !Task.isCancelled && generation == transitionGeneration else { return }

        let success = await budsController.pullBuds()
        guard !Task.isCancelled && generation == transitionGeneration else { return }

        if success {
            lastFailedPullAt = nil
            ownership = .macActive
            lastHandoffCompletedAt = nowProvider()
            transmit(opcode: .stateSync, reason: reason, state: .budsConnected)
            onHandoffCompleted?(.mac, reason)
        } else {
            lastFailedPullAt = nowProvider()
            if budsController.isBudsConnectedToMac {
                ownership = .macActive
                transmit(opcode: .stateSync, reason: .none, state: .budsConnected)
            } else {
                ownership = phoneReportedBudsConnected ? .phoneActive : .idle
                transmit(opcode: .stateSync, reason: .none, state: .idle)
            }
        }
    }

    private func executeReleaseToPhone(reason: HandoffReason, generation: UInt64) async {
        defer {
            if generation == transitionGeneration {
                activeTransitionTask = nil
            }
        }
        guard !Task.isCancelled && generation == transitionGeneration else { return }

        cancelPendingDebounce()
        ownership = .handingOffToPhone
        let released = await budsController.releaseBuds()
        guard !Task.isCancelled && generation == transitionGeneration else { return }

        if released {
            ownership = .phoneActive
            let now = nowProvider()
            lastHandoffCompletedAt = now
            lastBudsDisconnectedAt = now
            transmit(opcode: .released, reason: reason, state: .idle)
            onHandoffCompleted?(.phone, reason)
        } else if budsController.isBudsConnectedToMac {
            logger.warning("Failed to release Buds; Buds remain connected to Mac")
            ownership = .macActive
            transmit(opcode: .stateSync, reason: .none, state: .budsConnected)
        } else {
            ownership = .idle
            transmit(opcode: .stateSync, reason: .none, state: .idle)
        }
    }

    private func waitForPeerReleaseOrTimeout() async {
        guard !Task.isCancelled else { return }
        let timeout = peerReleaseWaitTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumePendingPeerRelease()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingPeerReleaseContinuation = continuation
        }
        timeoutTask.cancel()
    }

    private func resumePendingPeerRelease() {
        guard let continuation = pendingPeerReleaseContinuation else { return }
        pendingPeerReleaseContinuation = nil
        continuation.resume()
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

    private func remainingCooldown() -> Duration {
        guard let lastHandoffCompletedAt else { return .zero }
        let elapsed = nowProvider() - lastHandoffCompletedAt
        return elapsed < cooldownDuration ? (cooldownDuration - elapsed) : .zero
    }

    private func isInCooldown() -> Bool {
        remainingCooldown() > .zero
    }

    private func isInPostDisconnectGrace() -> Bool {
        guard let lastBudsDisconnectedAt else { return false }
        return (nowProvider() - lastBudsDisconnectedAt) < cooldownDuration
    }

    private func cancelPendingDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }
}
