import Foundation
import Testing
@testable import SamsungSwitchCore

@MainActor
private final class MockBLETransport: BLETransport {
    var status: BLELinkStatus = .connected(subscriberCount: 1)
    var onStatusChanged: ((BLELinkStatus) -> Void)?
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

    func pullBuds() async -> Bool {
        pullCount += 1
        if pullResult {
            isBudsConnectedToMac = true
        }
        return pullResult
    }

    func releaseBuds() async -> Bool {
        releaseCount += 1
        isBudsConnectedToMac = false
        return true
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
            cooldownDuration: .milliseconds(2500)
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
            cooldownDuration: .milliseconds(2500)
        )
        sm.handleRemoteFrame(HandoffFrame(opcode: .stateSync, reason: .none, state: .playing, seq: 1))

        // Act
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(90))

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
            cooldownDuration: .milliseconds(2500)
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
            nowProvider: { currentTime }
        )
        sm.handleRemoteFrame(HandoffFrame(opcode: .stateSync, reason: .none, state: .budsConnected, seq: 1))

        // Act: Mac pulls Buds
        sm.handleLocalAudioChanged(isPlaying: true)
        try await Task.sleep(for: .milliseconds(50))
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
            mediaPauser: pauser
        )

        // Act
        sm.handleMacWillSleep()
        try await Task.sleep(for: .milliseconds(20))

        // Assert
        #expect(buds.releaseCount == 1)
        #expect(ble.sentFrames.last?.opcode == .released)
    }
}
