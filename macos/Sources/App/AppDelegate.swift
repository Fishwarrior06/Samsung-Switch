import AppKit
import Foundation
import os
import SamsungSwitchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "App")
    private let bleServer = BLEGattServer()
    private let audioMonitor = CoreAudioMonitor()
    private lazy var budsController = IOBluetoothBudsController(audioMonitor: audioMonitor)
    private let mediaPauser = MacMediaPauser()
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
        wireComponents()
        bleServer.start()
        audioMonitor.start()
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

        let accessibilityTitle = mediaPauser.isAccessibilityAuthorized
            ? "Mac Auto-Pause: Authorized"
            : "Enable Mac Auto-Pause (Accessibility)..."
        let accessibilityItem = NSMenuItem(
            title: accessibilityTitle,
            action: #selector(requestAccessibilityAction),
            keyEquivalent: ""
        )
        accessibilityItem.target = self
        accessibilityItem.isEnabled = !mediaPauser.isAccessibilityAuthorized
        menu.addItem(accessibilityItem)
        accessibilityMenuItem = accessibilityItem

        menu.addItem(.separator())

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
                self?.bleServer.resumeAfterWake()
            }
        }
    }

    private func wireComponents() {
        bleServer.onStatusChanged = { [weak self] status in
            self?.statusMenuItem.title = "BLE: \(status.displayText)"
        }
        bleServer.onFrameReceived = { [weak self] frame in
            guard let self else { return }
            self.lastRxMenuItem.title = "Last RX: \(frame.summary)"
            self.stateMachine.handleRemoteFrame(frame)
        }
        audioMonitor.onRunningChanged = { [weak self] isPlaying in
            self?.stateMachine.handleLocalAudioChanged(isPlaying: isPlaying)
        }
        audioMonitor.onOutputDeviceChanged = { [weak self] deviceName in
            self?.audioMenuItem.title = "Output: \(deviceName)"
        }
        stateMachine.onStateChanged = { [weak self] in
            guard let self else { return }
            let callSuffix = self.stateMachine.isPhoneInCall ? " [CALL LOCK]" : ""
            self.ownershipMenuItem.title = "State: \(self.stateMachine.ownership.rawValue)\(callSuffix)"
        }
        stateMachine.onFrameTransmitted = { [weak self] frame in
            self?.lastTxMenuItem.title = "Last TX: \(frame.summary)"
        }

        statusMenuItem.title = "BLE: \(bleServer.status.displayText)"
        audioMenuItem.title = "Output: \(audioMonitor.defaultOutputDeviceName)"
    }

    @objc private func toggleAutoSwitchAction() {
        let next = !stateMachine.isAutoSwitchEnabled
        stateMachine.setAutoSwitchEnabled(next)
        autoSwitchMenuItem?.state = next ? .on : .off
    }

    @objc private func pullBudsAction() {
        stateMachine.handleManualPull()
    }

    @objc private func releaseBudsAction() {
        stateMachine.handleManualRelease()
    }

    @objc private func requestAccessibilityAction() {
        mediaPauser.requestAccessibilityOptIn()
        let authorized = mediaPauser.isAccessibilityAuthorized
        accessibilityMenuItem?.title = authorized
            ? "Mac Auto-Pause: Authorized"
            : "Enable Mac Auto-Pause (Accessibility)..."
        accessibilityMenuItem?.isEnabled = !authorized
    }

    @objc private func restartAdvertisingAction() {
        bleServer.restartAdvertising()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
