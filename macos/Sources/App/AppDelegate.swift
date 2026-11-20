import AppKit
import Foundation
import os
import SamsungSwitchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "App")
    private let bleServer: BLETransport = BLEGattServer()

    private var statusItem: NSStatusItem?
    private let statusMenuItem = NSMenuItem(title: "BLE: Starting...", action: nil, keyEquivalent: "")
    private let lastRxMenuItem = NSMenuItem(title: "Last RX: —", action: nil, keyEquivalent: "")
    private let lastTxMenuItem = NSMenuItem(title: "Last TX: —", action: nil, keyEquivalent: "")

    private var sequenceNumber: UInt16 = 0
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupSleepWakeObservers()
        setupBLECallbacks()
        bleServer.start()
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
            button.toolTip = "Samsung Switch BLE Link"
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        lastRxMenuItem.isEnabled = false
        lastTxMenuItem.isEnabled = false

        menu.addItem(statusMenuItem)
        menu.addItem(lastRxMenuItem)
        menu.addItem(lastTxMenuItem)
        menu.addItem(.separator())

        let sendSyncItem = NSMenuItem(
            title: "Send STATE_SYNC (Phase 1 Test)",
            action: #selector(sendStateSyncAction),
            keyEquivalent: ""
        )
        sendSyncItem.target = self
        menu.addItem(sendSyncItem)

        let sendHeartbeatItem = NSMenuItem(
            title: "Send HEARTBEAT_ACK (Phase 1 Test)",
            action: #selector(sendHeartbeatAckAction),
            keyEquivalent: ""
        )
        sendHeartbeatItem.target = self
        menu.addItem(sendHeartbeatItem)

        let sendClaimItem = NSMenuItem(
            title: "Send CLAIM (MANUAL)",
            action: #selector(sendManualClaimAction),
            keyEquivalent: ""
        )
        sendClaimItem.target = self
        menu.addItem(sendClaimItem)

        let sendReleasedItem = NSMenuItem(
            title: "Send RELEASED",
            action: #selector(sendReleasedAction),
            keyEquivalent: ""
        )
        sendReleasedItem.target = self
        menu.addItem(sendReleasedItem)

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

    private func setupBLECallbacks() {
        bleServer.onStatusChanged = { [weak self] status in
            self?.statusMenuItem.title = "BLE: \(status.displayText)"
        }
        bleServer.onFrameReceived = { [weak self] frame in
            guard let self else { return }
            self.lastRxMenuItem.title = "Last RX: \(frame.summary)"
            self.handleIncomingFrame(frame)
        }
        statusMenuItem.title = "BLE: \(bleServer.status.displayText)"
    }

    private func handleIncomingFrame(_ frame: HandoffFrame) {
        // Phase 1 bidirectional verification: acknowledge incoming frames except HEARTBEAT_ACK itself
        // to avoid echo loops.
        guard frame.opcode != .heartbeatAck else { return }
        let ack = HandoffFrame(
            opcode: .heartbeatAck,
            reason: frame.reason,
            state: .idle,
            seq: frame.seq
        )
        if bleServer.sendFrame(ack) {
            lastTxMenuItem.title = "Last TX: \(ack.summary)"
        }
    }

    private func nextSequence() -> UInt16 {
        sequenceNumber &+= 1
        return sequenceNumber
    }

    private func transmitFrame(opcode: HandoffOpcode, reason: HandoffReason, state: PeerState) {
        let frame = HandoffFrame(
            opcode: opcode,
            reason: reason,
            state: state,
            seq: nextSequence()
        )
        _ = bleServer.sendFrame(frame)
        lastTxMenuItem.title = "Last TX: \(frame.summary)"
    }

    @objc private func sendStateSyncAction() {
        transmitFrame(opcode: .stateSync, reason: .none, state: .idle)
    }

    @objc private func sendHeartbeatAckAction() {
        transmitFrame(opcode: .heartbeatAck, reason: .manual, state: .idle)
    }

    @objc private func sendManualClaimAction() {
        transmitFrame(opcode: .claim, reason: .manual, state: .playing)
    }

    @objc private func sendReleasedAction() {
        transmitFrame(opcode: .released, reason: .none, state: .idle)
    }

    @objc private func restartAdvertisingAction() {
        bleServer.restartAdvertising()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
