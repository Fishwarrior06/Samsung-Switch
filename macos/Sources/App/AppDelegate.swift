import AppKit
import Foundation
import os
import SamsungSwitchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "App")
    private let bleServer = BLEGattServer()
    private let audioMonitor = CoreAudioMonitor()
    private lazy var budsController = IOBluetoothBudsController(audioMonitor: audioMonitor)
    private let mediaPauser = MacMediaPauser()
    private let diagnosticBuffer = DiagnosticLogBuffer()
    private lazy var stateMachine = HandoffStateMachine(
        bleTransport: bleServer,
        budsController: budsController,
        mediaPauser: mediaPauser
    )

    private var statusItem: NSStatusItem?
    private let statusMenuItem = NSMenuItem(title: "BLE: Starting...", action: nil, keyEquivalent: "")
    private let ownershipMenuItem = NSMenuItem(title: "State: idle", action: nil, keyEquivalent: "")
    private let audioMenuItem = NSMenuItem(title: "Output: —", action: nil, keyEquivalent: "")
    private let lastRxMenuItem = NSMenuItem(title: "Last RX: —", action: nil, keyEquivalent: "")
    private let lastTxMenuItem = NSMenuItem(title: "Last TX: —", action: nil, keyEquivalent: "")
    private var autoSwitchMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupSleepWakeObservers()
        audioMonitor.start()
        wireComponents()
        stateMachine.syncInitialBudsConnection(connectedToMac: audioMonitor.isBudsActiveOutput())
        bleServer.start()
        diagnosticBuffer.append("Launched macOS menu-bar agent")
        logger.info("Samsung Switch macOS menu-bar service launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            workspaceCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            workspaceCenter.removeObserver(wakeObserver)
        }
        audioMonitor.stop()
        bleServer.stop()
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            refreshAccessibilityMenuItem()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let symbol = NSImage(
                systemSymbolName: "dot.radiowaves.left.and.right",
                accessibilityDescription: "Samsung Switch"
            )
            symbol?.isTemplate = true
            button.image = symbol
            if symbol == nil {
                button.title = "SSw"
            }
            button.toolTip = "Samsung Switch"
        }

        let menu = NSMenu()
        menu.delegate = self
        [statusMenuItem, ownershipMenuItem, audioMenuItem, lastRxMenuItem, lastTxMenuItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        menu.addItem(.separator())

        let autoItem = NSMenuItem(
            title: "Auto-Switch Enabled",
            action: #selector(toggleAutoSwitchAction),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.state = .on
        menu.addItem(autoItem)
        autoSwitchMenuItem = autoItem

        let pullItem = NSMenuItem(
            title: "Pull Buds Here",
            action: #selector(pullBudsAction),
            keyEquivalent: "p"
        )
        pullItem.target = self
        menu.addItem(pullItem)

        let releaseItem = NSMenuItem(
            title: "Release Buds to Phone",
            action: #selector(releaseBudsAction),
            keyEquivalent: ""
        )
        releaseItem.target = self
        menu.addItem(releaseItem)

        let accessibilityItem = NSMenuItem(
            title: "Enable Mac Auto-Pause (Accessibility)...",
            action: #selector(requestAccessibilityAction),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        accessibilityMenuItem = accessibilityItem
        refreshAccessibilityMenuItem()

        menu.addItem(.separator())

        let copyDiagItem = NSMenuItem(
            title: "Copy Diagnostic Summary",
            action: #selector(copyDiagnosticSummaryAction),
            keyEquivalent: ""
        )
        copyDiagItem.target = self
        menu.addItem(copyDiagItem)

        let restartItem = NSMenuItem(
            title: "Restart BLE Advertising",
            action: #selector(restartAdvertisingAction),
            keyEquivalent: "r"
        )
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(
            title: "Quit Samsung Switch",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func setupSleepWakeObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.diagnosticBuffer.append("Mac sleeping: releasing Buds & pausing BLE")
                self?.stateMachine.handleMacWillSleep()
                self?.bleServer.pauseForSleep()
            }
        }
        wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.diagnosticBuffer.append("Mac woke: reconciling Buds state & resuming BLE advertising")
                self?.stateMachine.handleMacDidWake()
                self?.bleServer.resumeAfterWake()
            }
        }
    }

    private func wireComponents() {
        bleServer.onStatusChanged = { [weak self] status in
            guard let self else { return }
            self.statusMenuItem.title = "BLE: \(status.displayText)"
            self.diagnosticBuffer.append("BLE -> \(status.displayText)")
        }
        bleServer.onPeerSubscribed = { [weak self] in
            self?.stateMachine.handlePeerConnected()
        }
        bleServer.onFrameReceived = { [weak self] frame in
            guard let self else { return }
            self.lastRxMenuItem.title = "Last RX: \(frame.summary)"
            self.diagnosticBuffer.append("RX: \(frame.summary)")
            self.stateMachine.handleRemoteFrame(frame)
        }
        audioMonitor.onRunningChanged = { [weak self] isPlaying in
            self?.diagnosticBuffer.append("CoreAudio running -> \(isPlaying)")
            self?.stateMachine.handleLocalAudioChanged(isPlaying: isPlaying)
        }
        audioMonitor.onPlaybackActivityDetected = { [weak self] in
            self?.diagnosticBuffer.append("CoreAudio new audio output process detected")
            self?.stateMachine.handleLocalAudioActivityDetected()
        }
        audioMonitor.onOutputDeviceChanged = { [weak self] deviceName in
            guard let self else { return }
            self.audioMenuItem.title = "Output: \(deviceName)"
            self.diagnosticBuffer.append("Output -> \(deviceName)")
            self.stateMachine.handleBudsOutputChanged(
                connectedToMac: self.audioMonitor.isBudsActiveOutput()
            )
        }
        stateMachine.onStateChanged = { [weak self] in
            guard let self else { return }
            let callSuffix = self.stateMachine.isPhoneInCall ? " [CALL LOCK]" : ""
            let stateText = "\(self.stateMachine.ownership.rawValue)\(callSuffix)"
            self.ownershipMenuItem.title = "State: \(stateText)"
            self.diagnosticBuffer.append("State -> \(stateText)")
        }
        stateMachine.onFrameTransmitted = { [weak self] frame in
            self?.lastTxMenuItem.title = "Last TX: \(frame.summary)"
            self?.diagnosticBuffer.append("TX: \(frame.summary)")
        }
        stateMachine.onHandoffCompleted = { [weak self] destination, reason in
            self?.diagnosticBuffer.append("Handoff completed -> \(destination.rawValue) (\(reason))")
        }

        statusMenuItem.title = "BLE: \(bleServer.status.displayText)"
        audioMenuItem.title = "Output: \(audioMonitor.defaultOutputDeviceName)"
    }

    private func refreshAccessibilityMenuItem() {
        let authorized = mediaPauser.isAccessibilityAuthorized
        accessibilityMenuItem?.title = authorized
            ? "Mac Auto-Pause: Authorized"
            : "Enable Mac Auto-Pause (Accessibility)..."
        accessibilityMenuItem?.isEnabled = !authorized
    }

    @objc private func toggleAutoSwitchAction() {
        let next = !stateMachine.isAutoSwitchEnabled
        stateMachine.setAutoSwitchEnabled(next)
        autoSwitchMenuItem?.state = next ? .on : .off
        diagnosticBuffer.append("Auto-Switch -> \(next)")
    }

    @objc private func pullBudsAction() {
        diagnosticBuffer.append("Manual Pull requested")
        stateMachine.handleManualPull()
    }

    @objc private func releaseBudsAction() {
        diagnosticBuffer.append("Manual Release requested")
        stateMachine.handleManualRelease()
    }

    @objc private func requestAccessibilityAction() {
        mediaPauser.requestAccessibilityOptIn()
        refreshAccessibilityMenuItem()
    }

    @objc private func copyDiagnosticSummaryAction() {
        let callSuffix = stateMachine.isPhoneInCall ? " [CALL LOCK]" : ""
        let report = diagnosticBuffer.formattedReport(
            bleStatus: bleServer.status.displayText,
            ownership: "\(stateMachine.ownership.rawValue)\(callSuffix)",
            outputDevice: audioMonitor.defaultOutputDeviceName,
            accessibilityAuthorized: mediaPauser.isAccessibilityAuthorized
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    @objc private func restartAdvertisingAction() {
        diagnosticBuffer.append("Restarting BLE advertising")
        bleServer.restartAdvertising()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
