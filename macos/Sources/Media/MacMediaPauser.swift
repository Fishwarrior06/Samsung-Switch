import AppKit
import ApplicationServices
import Foundation
import os

@MainActor
public final class MacMediaPauser: MediaPausing {
    private let logger = Logger(subsystem: "com.samsungswitch.macos", category: "MacMediaPauser")

    public init() {}

    public var isAccessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibilityOptIn() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanTrue] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func pauseLocalMediaIfPlaying(isPlaying: Bool) {
        guard isPlaying else { return }
        guard AXIsProcessTrusted() else {
            logger.debug("Accessibility not granted; skipping synthetic media pause key")
            return
        }
        sendMediaPlayPauseKey()
        logger.info("Sent synthetic media play/pause key to pause Mac playback")
    }

    private func sendMediaPlayPauseKey() {
        let keyCode = Int32(16) // NX_KEYTYPE_PLAY
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0x0A00 : 0x0B00)
            let data1 = Int((keyCode << 16) | (isDown ? 0x0A00 : 0x0B00))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
