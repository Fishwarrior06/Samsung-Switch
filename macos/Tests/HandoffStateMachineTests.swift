import Foundation
import Testing
@testable import SamsungSwitchCore

@MainActor
private final class MockBLETransport: BLETransport {
    var status: BLELinkStatus = .connected(subscriberCount: 1)
    var onStatusChanged: ((BLELinkStatus) -> Void)?
    var onPeerSubscribed: (() -> Void)?
    var onFrameReceived: ((HandoffFrame) -> Void)?
    var sentFrames: [HandoffFrame] = []

    func start() {}
    func stop() {}
    func restartAdvertising() {}
    func pauseForSleep() {}
    func resumeAfterWake() {}

    @discardableResult
    func sendFrame(_ frame: HandoffFrame) -> Bool {
        sentFrames.append(frame)
        return true
    }
}

@MainActor
private final class MockBudsController: BudsControlling {
    var budsDisplayName: String? = "Buds3 Pro"
    var isBudsConnectedToMac: Bool = false
    var pullCount = 0
    var releaseCount = 0
    var pullResult = true
    var releaseResult = true
    var pullDelay: Duration?

    func pullBuds() async -> Bool {
        pullCount += 1
        if let pullDelay {
            try? await Task.sleep(for: pullDelay)
        }
        if pullResult {
            isBudsConnectedToMac = true
        }
        return pullResult
    }

    func releaseBuds() async -> Bool {
        releaseCount += 1
        if releaseResult {
            isBudsConnectedToMac = false
        }
        return releaseResult
    }
}

@MainActor
private final class MockMediaPauser: MediaPausing {
    var pauseCalls: [Bool] = []

    func pauseLocalMediaIfPlaying(isPlaying: Bool) {
        pauseCalls.append(isPlaying)
    }
}

@Suite("HandoffStateMachine Priority, Debounce, and Cooldown")
@MainActor
struct HandoffStateMachineTests {

    @Test("Short Mac notification (< debounce) does not trigger handoff")
    func shortMacAudio_belowDebounce_doesNotPullBuds() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            mediaDebounce: .milliseconds(80),
            cooldownDuration: .milliseconds(2500),
            peerReleaseWaitTimeout: .milliseconds(30)
        )
        sm.handleRemoteFrame(HandoffFrame(opcode: .stateSync, reason: .none, state: .budsConnected, seq: 1))

        // Act
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(20))
        sm.handleLocalAudioChanged(isPlaying: false)
        try await Task.sleep(for: .milliseconds(100))

        // Assert
        #expect(buds.pullCount == 0)
        #expect(ble.sentFrames.isEmpty)
    }

    @Test("Sustained Mac media after debounce claims and pulls Buds")
    func sustainedMacAudio_afterDebounce_pullsBuds() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            mediaDebounce: .milliseconds(40),
            cooldownDuration: .milliseconds(2500),
            peerReleaseWaitTimeout: .milliseconds(30)
        )
        sm.handleRemoteFrame(HandoffFrame(opcode: .stateSync, reason: .none, state: .playing, seq: 1))

        // Act
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(120))

        // Assert
        #expect(buds.pullCount == 1)
        #expect(sm.ownership == .macActive)
        #expect(ble.sentFrames.first?.opcode == .claim)
        #expect(ble.sentFrames.first?.reason == .media)
    }

    @Test("Phone CALL claim preempts immediately with 0ms debounce and locks Mac pulls")
    func phoneCallClaim_preemptsImmediatelyAndLocksMac() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        buds.isBudsConnectedToMac = true
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            mediaDebounce: .milliseconds(40),
            cooldownDuration: .milliseconds(2500),
            peerReleaseWaitTimeout: .milliseconds(30)
        )
        sm.handleLocalAudioChanged(isPlaying: true)

        // Act
        sm.handleRemoteFrame(HandoffFrame(opcode: .claim, reason: .call, state: .inCall, seq: 10))
        try await Task.sleep(for: .milliseconds(30))

        // Assert
        #expect(sm.isPhoneInCall == true)
        #expect(pauser.pauseCalls == [true])
        #expect(buds.releaseCount == 1)
        #expect(ble.sentFrames.last?.opcode == .released)
        #expect(ble.sentFrames.last?.reason == .call)

        // Act: Mac manual pull while in call must be rejected
        sm.handleManualPull()
        try await Task.sleep(for: .milliseconds(20))

        // Assert
        #expect(buds.pullCount == 0)
    }

    @Test("Post-handoff cooldown blocks rapid ping-pong phone media claim")
    func postHandoffCooldown_ignoresRapidPhoneMediaBounce() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        var currentTime = ContinuousClock.now
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            mediaDebounce: .milliseconds(10),
            cooldownDuration: .milliseconds(2500),
            peerReleaseWaitTimeout: .milliseconds(30),
            nowProvider: { currentTime }
        )
        sm.handleRemoteFrame(HandoffFrame(opcode: .stateSync, reason: .none, state: .budsConnected, seq: 1))

        // Act: Mac pulls Buds
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(sm.ownership == .macActive)

        // Advance only 500ms (inside 2500ms cooldown) and receive phone MEDIA claim
        currentTime = currentTime + .milliseconds(500)
        sm.handleRemoteFrame(HandoffFrame(opcode: .claim, reason: .media, state: .playing, seq: 2))
        try await Task.sleep(for: .milliseconds(20))

        // Assert: Ignored during cooldown
        #expect(buds.releaseCount == 0)
        #expect(sm.ownership == .macActive)
    }

    @Test("Mac sleep releases Buds if currently held")
    func macSleep_whenMacActive_releasesBuds() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        buds.isBudsConnectedToMac = true
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            peerReleaseWaitTimeout: .milliseconds(30)
        )

        // Act
        sm.handleMacWillSleep()
        try await Task.sleep(for: .milliseconds(20))

        // Assert
        #expect(buds.releaseCount == 1)
        #expect(ble.sentFrames.last?.opcode == .released)
    }

    @Test("Pull to Mac resumes immediately when phone sends RELEASED")
    func pullToMac_resumesImmediatelyWhenPhoneSendsReleased() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            peerReleaseWaitTimeout: .seconds(5)
        )

        // Act
        let started = ContinuousClock.now
        sm.handleManualPull()
        try await Task.sleep(for: .milliseconds(15))
        sm.handleRemoteFrame(HandoffFrame(opcode: .released, reason: .manual, state: .idle, seq: 99))
        try await Task.sleep(for: .milliseconds(30))
        let elapsed = ContinuousClock.now - started

        // Assert
        #expect(buds.pullCount == 1)
        #expect(sm.ownership == .macActive)
        #expect(elapsed < .milliseconds(500))
    }

    @Test("Failed pull to Mac transmits STATE_SYNC(IDLE)")
    func failedPullToMac_transmitsStateSyncIdle() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        buds.pullResult = false
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            peerReleaseWaitTimeout: .milliseconds(20)
        )

        // Act
        sm.handleManualPull()
        try await Task.sleep(for: .milliseconds(60))

        // Assert
        #expect(buds.pullCount == 1)
        #expect(sm.ownership == .idle)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .idle)
    }

    @Test("Manual Buds output change syncs ownership and notifies phone")
    func manualBudsOutputChange_syncsOwnershipAndNotifiesPhone() {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser
        )

        // Act
        sm.handleBudsOutputChanged(connectedToMac: true)

        // Assert
        #expect(sm.ownership == .macActive)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .budsConnected)

        // Act: disconnected outside state machine
        sm.handleBudsOutputChanged(connectedToMac: false)

        // Assert
        #expect(sm.ownership == .idle)
    }

    @Test("Mac audio bounce during cooldown is dropped to prevent ping-pong")
    func macAudioBounceDuringCooldown_isDroppedToPreventPingPong() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        buds.isBudsConnectedToMac = true
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            mediaDebounce: .milliseconds(20),
            cooldownDuration: .milliseconds(100),
            peerReleaseWaitTimeout: .milliseconds(20)
        )

        // Release to phone -> enters 100ms cooldown
        sm.handleRemoteFrame(HandoffFrame(opcode: .claim, reason: .media, state: .playing, seq: 1))
        try await Task.sleep(for: .milliseconds(20))
        #expect(sm.ownership == .phoneActive)

        // Act: CoreAudio bounces to running during cooldown -> must be dropped completely
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(140))

        // Assert: Bounce never schedules a delayed steal back to Mac
        #expect(buds.pullCount == 0)
        #expect(sm.ownership == .phoneActive)

        // Act: Fresh playback after cooldown expires pulls cleanly
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(60))

        // Assert
        #expect(buds.pullCount == 1)
        #expect(sm.ownership == .macActive)
    }

    @Test("Auto pull is blocked when BLE disconnected while manual pull remains allowed")
    func autoPullWhenBleDisconnected_isBlockedButManualPullAllowed() async throws {
        // Arrange
        let ble = MockBLETransport()
        ble.status = .advertising
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            mediaDebounce: .milliseconds(20),
            cooldownDuration: .milliseconds(2500),
            peerReleaseWaitTimeout: .milliseconds(20)
        )

        // Act: Automatic audio start while phone is not connected over BLE
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(60))

        // Assert: Auto pull suppressed
        #expect(buds.pullCount == 0)
        #expect(sm.ownership == .idle)

        // Act: Explicit manual pull still works
        sm.handleManualPull()
        try await Task.sleep(for: .milliseconds(40))

        // Assert
        #expect(buds.pullCount == 1)
        #expect(sm.ownership == .macActive)
    }

    @Test("External Buds disconnect suppresses immediate speaker-migration audio bounce")
    func externalBudsDisconnect_suppressesImmediateSpeakerBounce() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            mediaDebounce: .milliseconds(20),
            cooldownDuration: .milliseconds(120),
            peerReleaseWaitTimeout: .milliseconds(20)
        )

        // Buds disconnected from Mac externally (e.g., phone took them)
        sm.handleBudsOutputChanged(connectedToMac: false)

        // Act: Immediate speaker-migration audio bounce on Mac
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(60))

        // Assert: Suppressed during grace window
        #expect(buds.pullCount == 0)
        #expect(sm.ownership == .idle)
    }

    @Test("New audio activity while device is already running triggers pull and fires banner callback")
    func newAudioActivityWhileAlreadyRunning_triggersPullToMac() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        var completedEvents: [(HandoffDestination, HandoffReason)] = []
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            mediaDebounce: .milliseconds(20),
            cooldownDuration: .milliseconds(2500),
            peerReleaseWaitTimeout: .milliseconds(20)
        )
        sm.onHandoffCompleted = { destination, reason in
            completedEvents.append((destination, reason))
        }

        // Act
        sm.handleLocalAudioActivityDetected()
        try await Task.sleep(for: .milliseconds(80))

        // Assert
        #expect(buds.pullCount == 1)
        #expect(sm.ownership == .macActive)
        #expect(completedEvents.count == 1)
        #expect(completedEvents[0].0 == .mac)
        #expect(completedEvents[0].1 == .media)
    }

    @Test("Peer reconnect resends authoritative STATE_SYNC based on Mac Buds output")
    func peerReconnect_resendsAuthoritativeStateSync() {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser
        )

        // Act: Buds currently active on Mac
        buds.isBudsConnectedToMac = true
        sm.handlePeerConnected()

        // Assert
        #expect(sm.ownership == .macActive)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .budsConnected)

        // Act: Buds disconnected from Mac
        buds.isBudsConnectedToMac = false
        sm.handlePeerConnected()

        // Assert
        #expect(sm.ownership == .idle)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .idle)
    }

    @Test("Failed release when Buds remain on Mac keeps macActive and syncs")
    func failedRelease_whenBudsRemainOnMac_keepsMacActiveAndSyncs() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        buds.isBudsConnectedToMac = true
        buds.releaseResult = false
        let pauser = MockMediaPauser()
        var bannerCount = 0
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            peerReleaseWaitTimeout: .milliseconds(20)
        )
        sm.syncInitialBudsConnection(connectedToMac: true)
        sm.onHandoffCompleted = { _, _ in bannerCount += 1 }

        // Act
        sm.handleRemoteFrame(HandoffFrame(opcode: .claim, reason: .media, state: .playing, seq: 1))
        try await Task.sleep(for: .milliseconds(40))

        // Assert
        #expect(buds.releaseCount == 1)
        #expect(sm.ownership == .macActive)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .budsConnected)
        #expect(bannerCount == 0)
    }

    @Test("Phone CALL claim during in-flight Mac pull cancels pull and releases cleanly")
    func phoneCallClaim_duringInFlightMacPull_cancelsPullAndReleasesCleanly() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        buds.pullDelay = .milliseconds(80)
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            peerReleaseWaitTimeout: .milliseconds(20)
        )

        // Act: start slow pull, then preempt with CALL while pullBuds() is still running
        sm.handleManualPull()
        try await Task.sleep(for: .milliseconds(35))
        sm.handleRemoteFrame(HandoffFrame(opcode: .claim, reason: .call, state: .inCall, seq: 7))
        try await Task.sleep(for: .milliseconds(120))

        // Assert
        #expect(buds.releaseCount == 1)
        #expect(sm.ownership == .phoneActive)
        #expect(sm.isPhoneInCall == true)
        #expect(ble.sentFrames.last?.opcode == .released)
        #expect(ble.sentFrames.last?.reason == .call)
    }

    @Test("Remote STATE_SYNC(IDLE) reconciles stale phoneActive")
    func remoteStateSyncIdle_reconcilesStalePhoneActive() async throws {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser,
            peerReleaseWaitTimeout: .milliseconds(20)
        )

        // Move into phoneActive first
        sm.handleManualRelease()
        try await Task.sleep(for: .milliseconds(30))
        #expect(sm.ownership == .phoneActive)
        ble.sentFrames.removeAll()

        // Act 1: phone reports IDLE while Buds are actually connected to Mac
        buds.isBudsConnectedToMac = true
        sm.handleRemoteFrame(HandoffFrame(opcode: .stateSync, reason: .none, state: .idle, seq: 11))

        // Assert 1
        #expect(sm.ownership == .macActive)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .budsConnected)

        // Move back to phoneActive, then phone reports IDLE with Buds disconnected everywhere
        buds.isBudsConnectedToMac = false
        sm.handleManualRelease()
        try await Task.sleep(for: .milliseconds(30))
        #expect(sm.ownership == .phoneActive)

        // Act 2
        sm.handleRemoteFrame(HandoffFrame(opcode: .stateSync, reason: .none, state: .idle, seq: 12))

        // Assert 2
        #expect(sm.ownership == .idle)
    }

    @Test("Mac wake reconciles actual Buds connection")
    func macWake_reconcilesActualBudsConnection() {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser
        )

        // Act 1: wake with Buds connected to Mac while ownership was idle
        buds.isBudsConnectedToMac = true
        sm.handleMacDidWake()

        // Assert 1
        #expect(sm.ownership == .macActive)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .budsConnected)

        // Act 2: wake after Buds dropped while asleep
        buds.isBudsConnectedToMac = false
        sm.handleMacDidWake()

        // Assert 2
        #expect(sm.ownership == .idle)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .idle)
    }

    @Test("External Buds disconnect from macActive transmits STATE_SYNC(IDLE)")
    func externalBudsDisconnect_fromMacActive_transmitsStateSyncIdle() {
        // Arrange
        let ble = MockBLETransport()
        let buds = MockBudsController()
        let pauser = MockMediaPauser()
        let sm = HandoffStateMachine(
            bleTransport: ble,
            budsController: buds,
            mediaPauser: pauser
        )
        sm.syncInitialBudsConnection(connectedToMac: true)
        #expect(sm.ownership == .macActive)

        // Act
        sm.handleBudsOutputChanged(connectedToMac: false)

        // Assert
        #expect(sm.ownership == .idle)
        #expect(ble.sentFrames.last?.opcode == .stateSync)
        #expect(ble.sentFrames.last?.state == .idle)
    }
}
