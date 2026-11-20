# 🤖 AGENTS.md — AI Agent Contribution Guide

> This file defines how AI agents (Copilot, Claude, Antigravity, Cursor, etc.) should interact with this repository.
> All suggestions, refactors, and generated code must comply with the conventions, resource budgets, and platform constraints described here.

---

## 📌 Project Context

**Samsung Switch** is a dual-platform, ultra-lightweight native utility that brings seamless **Galaxy Buds Auto-Switch** between **macOS** and **Android (Samsung One UI)** over a private **Bluetooth Low Energy (BLE) GATT** control channel.

- **macOS (`macos/`):** Native **Swift 6** menu-bar app / daemon using `AppKit`, `CoreBluetooth`, `IOBluetooth`, and `CoreAudio`.
- **Android (`android/`):** Native **Kotlin** companion app (minSdk 31 / Android 12+) using `CompanionDeviceManager`, `BluetoothGatt`, `AudioManager`, and an abstracted `BudsConnector` (auto-reconnect / optional Shizuku A2DP backend).
- **Galaxy Buds:** Zero modifications, zero extra connections, zero extra battery/CPU impact.

**Hard Runtime Budgets (non-negotiable):**
- **macOS:** **< 20 MB RAM**, **~0.0% idle CPU**, **no Electron, no WebViews, no Python/Node runtimes, no polling timers**.
- **Android:** **< 1% battery/day**, **zero continuous CPU BLE scanning**, **zero WakeLocks**, audio listeners registered **only while the Mac BLE link is active**.

**Reference Directory Warning (`seuil/`):**
- If `seuil/` exists in the workspace, it is a **GPLv3 Linux reference repo only**.
- **Never copy, port, or link code from `seuil/`** into this project. Do not depend on Samsung's proprietary `0x0075` BLE Manufacturer Data (blocked by macOS `CoreBluetooth`).

---

## 🧭 Mandatory Context Review Before Design/Implementation

Before proposing designs or making code changes, agents must read the docs index and the relevant guides in `docs/`:

1. Start with [`docs/architecture-guide.md`](docs/architecture-guide.md) to understand the BLE roles, handoff flows, and hardware constraints.
2. Read `protocol/spec.md` (once created) before touching any BLE framing, opcodes, or UUIDs.
3. Read all matching feature guides in `docs/` before modifying existing flows.
4. Reuse established patterns and state-machine rules unless the task explicitly calls for an architectural change.

---

## 📄 Mandatory Post-Feature Documentation

Every feature or significant change shipped **must** include a new or updated guide under `docs/`.
This is not optional — the doc must be part of the same PR/commit set as the feature code.

### Naming Convention

```text
docs/<short-kebab-slug>.md
```

Examples:
```text
docs/phase-0-iobluetooth-spike.md
docs/ble-gatt-protocol-v1.md
docs/android-shizuku-a2dp-connector.md
docs/macos-coreaudio-debounce-tuning.md
```

### Required Sections

```markdown
# <Feature Title>

## Context
<!-- Why this change was needed and what problem it solves. -->

## What Changed
<!-- Enumerate every layer touched: macOS modules, Android modules, BLE protocol opcodes, permissions, etc. -->

### Protocol / Contract Changes (if any)
<!-- UUIDs, byte offsets, opcodes, backwards-compatibility notes. -->

## Resource Impact
<!-- Measured or expected impact on macOS RAM/CPU and Android battery/wakeups. -->

## Design Decisions
<!-- Non-obvious choices made and trade-offs considered. -->

## How to Test
<!-- Minimal steps to validate locally (unit tests + physical hardware test if applicable). -->
```

---

## 🗂️ Repository Structure

```text
.
├── macos/                       # Native Swift 6 macOS app / daemon
│   ├── Package.swift            # Swift Package Manager manifest (or XcodeGen project.yml)
│   ├── Sources/
│   │   ├── App/                 # Minimal AppKit menu-bar entry point & LaunchAgent helper
│   │   ├── BLE/                 # CBPeripheralManager GATT Server (custom 128-bit Service UUID)
│   │   ├── Audio/               # Passive CoreAudio output state listener + debounce
│   │   ├── Bluetooth/           # IOBluetoothDevice A2DP open/close wrapper
│   │   ├── Media/               # Local playback pause helper
│   │   ├── Protocol/            # 6-byte binary frame encoder/decoder
│   │   └── StateMachine/        # Pure Swift HandoffStateMachine (100% unit-testable)
│   └── Tests/                   # Pure unit tests (StateMachine, Protocol, Debouncer)
├── android/                     # Native Kotlin Android companion app (minSdk 31)
│   ├── app/src/main/java/com/samsungswitch/
│   │   ├── ble/                 # CompanionDeviceService + BluetoothGatt client (LOW_POWER)
│   │   ├── audio/               # AudioPlaybackCallback + call mode listener
│   │   ├── bluetooth/           # BudsConnector interface + AutoReconnect / Shizuku impls
│   │   ├── protocol/            # 6-byte binary frame encoder/decoder (mirrors macOS)
│   │   ├── state/               # Pure Kotlin handoff coordinator
│   │   └── ui/                  # Minimal setup & status Activity (no heavy background UI)
│   └── app/src/test/            # JUnit 5 + MockK unit tests
├── protocol/
│   └── spec.md                  # Single source of truth for BLE UUIDs, opcodes, and framing
├── docs/
│   └── architecture-guide.md    # Master architecture & phased roadmap
├── seuil/                       # (Optional local reference only — GPLv3, NEVER import/copy)
└── AGENTS.md
```

---

## 🍎 macOS (Swift) Conventions

### General Rules

- **Swift version:** Swift 6 (strict concurrency where practical), targeting macOS 14+.
- **UI framework:** Prefer lightweight **AppKit** (`NSStatusItem`, `NSMenu`) for the menu bar to stay strictly under **20 MB RAM**. Avoid heavy SwiftUI windows left alive in memory; destroy settings windows on close.
- **Zero polling:** Never use `Timer`, `sleep`, or `Process` shells (`blueutil`, `system_profiler`) in loops to detect audio or Bluetooth state. Always use system callbacks:
  - `CoreAudio`: `AudioObjectAddPropertyListenerBlock` on `kAudioDevicePropertyDeviceIsRunningSomewhere`.
  - `CoreBluetooth`: `CBPeripheralManagerDelegate`.
  - `NSWorkspace`: `willSleepNotification` / `didWakeNotification`.
- **Logging:** Use Apple Unified Logging (`os.Logger(subsystem:category:)`). Never use `print()` in production code.
- **Dependency injection:** Inject protocols (`AudioMonitor`, `BudsController`, `BLETransport`) into `HandoffStateMachine` so core logic is testable without physical hardware.
- **No third-party dependencies** unless strictly justified — Apple's native frameworks (`Foundation`, `AppKit`, `CoreBluetooth`, `IOBluetooth`, `CoreAudio`) cover everything needed.

### Naming Conventions (Swift)

| Element | Convention | Example |
|---|---|---|
| Types / Protocols | `PascalCase` | `HandoffStateMachine`, `BudsControlling` |
| Methods / Properties | `camelCase` | `handleLocalAudioStarted()` |
| Constants | `camelCase` (scoped in `enum`) | `ProtocolConstants.serviceUUID` |
| Files | Match primary type | `HandoffStateMachine.swift` |

---

## 🤖 Android (Kotlin) Conventions

### General Rules

- **Language / SDK:** Kotlin + Coroutines, `minSdk = 31` (Android 12+), `targetSdk` = latest stable.
- **Zero continuous BLE scanning:** Never run `startScan()` continuously in a foreground service. Always rely on `CompanionDeviceManager.startObservingDevicePresence` (hardware-offloaded filtering) + `connectGatt(..., autoConnect = true, ...)`.
- **Connection priority:** Always request `BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER` once service discovery finishes.
- **Lifecycle discipline:** Register `AudioManager.AudioPlaybackCallback` and call/mode listeners **only when connected to the Mac over BLE**, and unregister them immediately on BLE disconnect.
- **Zero WakeLocks:** Never acquire partial or full `PowerManager.WakeLock`.
- **A2DP connection abstraction:** Hide `BluetoothA2dp` reconnection behind a `BudsConnector` interface so the app cleanly supports both zero-privilege auto-reconnect and optional Shizuku privileged reconnect without leaking reflection/Shizuku details into business logic.
- **Logging:** Use a thin logger wrapper around `android.util.Log` (debug builds only for verbose frames). Never log device MAC addresses or PII in release logs.

### Naming Conventions (Kotlin)

| Element | Convention | Example |
|---|---|---|
| Classes / Interfaces | `PascalCase` | `BleGattClient`, `BudsConnector` |
| Functions / Variables | `camelCase` | `onRemoteClaimReceived()` |
| Constants | `UPPER_SNAKE_CASE` | `PROTOCOL_VERSION` |
| Packages | `lowercase` | `com.samsungswitch.ble` |

---

## 📡 BLE Protocol & State Machine Conventions

- **`protocol/spec.md` is the single source of truth.** Any change to UUIDs, opcodes, or byte offsets must be updated in `protocol/spec.md`, `macos/Sources/Protocol/`, and `android/.../protocol/` in the same commit/PR.
- **Binary framing must remain fixed-size and minimal** (6–8 bytes) — no JSON over BLE GATT.
- **Encryption is mandatory:** All writable/notifiable GATT characteristics must require BLE encryption (`.writeEncryptionRequired` / `.readEncryptionRequired`) so BLE Bonding protects the link.
- **Priority invariants (never violate):**
  1. Phone call (`CALL`) always preempts media with **0 ms debounce**.
  2. Media triggers must pass a **350–500 ms debounce** before initiating handoff.
  3. Enforce a **2.5 s post-handoff cooldown** to prevent ping-pong loops.
  4. Mac sleep (`willSleepNotification`) stops BLE advertising and releases Buds if held.

---

## 🧪 Testing Standards

All core logic changes **must** include unit tests. Hardware-dependent layers must be mocked behind protocols/interfaces.

### Running Tests

```bash
# macOS (Swift Package Manager)
cd macos && swift test

# Android (Gradle)
cd android && ./gradlew testDebugUnitTest
```

### Test Strategy

| Layer | macOS Tool | Android Tool | Scope |
|---|---|---|---|
| State Machine | Swift Testing / `XCTest` | JUnit 5 | Pure deterministic transitions, debounce, cooldown, call priority |
| Binary Protocol Codec | Swift Testing / `XCTest` | JUnit 5 | Round-trip encode/decode, malformed/truncated frames, endianness |
| BLE / Audio Coordinators | `XCTest` + protocol mocks | JUnit 5 + MockK | Event wiring without real hardware |
| Hardware E2E | Physical Mac + Galaxy Buds | Physical Samsung phone | Real A2DP switch latency, sleep/wake, 24 h battery check |

### Test Rules

- Follow the **AAA pattern** (Arrange → Act → Assert) with clear spacing.
- Test names must clearly state scenario and outcome (e.g., `claimFromMac_whenPhoneInCall_isRejected`).
- Every protocol change must have cross-platform test vectors (identical raw hex bytes verified on both Swift and Kotlin).

### Hardware E2E Validation Checklist (when touching BLE / Audio / Bluetooth)

1. Play audio on Samsung with Buds connected → press Play on Mac → verify Samsung pauses and Buds switch to Mac (< 2 s).
2. Play audio on Mac with Buds connected → play video on Samsung → verify Mac pauses and Buds switch to Samsung (< 2 s).
3. Play audio on Mac → trigger incoming call on Samsung → verify immediate switch (no media debounce).
4. Trigger a short macOS notification sound while listening on Samsung → verify **no false switch**.
5. Close Mac lid / sleep Mac while Buds are on Mac → verify Buds release cleanly and BLE stops advertising.
6. Verify macOS RAM (< 20 MB) and idle CPU (~0.0%) in Activity Monitor.

---

## 🔒 Security & Privacy Checks

- **Never** commit personal Bluetooth MAC addresses, device serial numbers, signing certificates, keystores (`.jks`, `.p12`), or provisioning profiles.
- **Never** disable BLE encryption/bonding requirements on GATT characteristics.
- **Zero telemetry / zero network permissions:** Neither the macOS app nor the Android app should request internet access (`android.permission.INTERNET` must **not** be in `AndroidManifest.xml`).
- **Minimal permissions only:**
  - macOS: `NSBluetoothAlwaysUsageDescription` only (no microphone, no accessibility unless explicitly opted in for media key fallback).
  - Android: `BLUETOOTH_CONNECT`, `REQUEST_OBSERVE_COMPANION_DEVICE_PRESENCE` (and Shizuku only if user enables privileged A2DP mode). No location permission (`ACCESS_FINE_LOCATION`) on Android 12+ (`neverForLocation`).

---

## 🛠️ IDE & Formatting Setup

### macOS (Swift / Xcode)
- **Indentation:** 4 spaces (no tabs).
- **Max line length:** 120 characters.
- **Formatting:** Follow standard Swift API Design Guidelines (`swift-format` / Xcode default).
- **Trailing newline** at the end of every file.

### Android (Kotlin / Android Studio)
- **Indentation:** 4 spaces (no tabs).
- **Max line length:** 120 characters.
- **Formatting:** Official Kotlin style guide (`ktlint` compatible).
- **No wildcard imports** (`import foo.*` forbidden).
- **Trailing newline** at the end of every file.

---

## 🌿 Git Workflow

### Branch Naming

```text
<type>/<scope>-short-description-in-kebab-case
```

Examples:
```text
feat/macos-ble-gatt-server
feat/android-companion-presence
fix/handoff-notification-false-trigger
docs/phase-0-iobluetooth-spike
```

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/) with **gitmoji** prefix:

```text
<gitmoji> <type>(scope): short imperative description
```

| Gitmoji | Type | When to use |
|---|---|---|
| ✨ | `feat` | New feature or platform capability |
| 🐛 | `fix` | Bug fix |
| ⚡️ | `perf` | RAM, CPU, latency, or battery optimization |
| ♻️ | `refactor` | Code refactor, no behavior change |
| 🧪 | `test` | Adding or updating tests |
| 🔒️ | `fix` | Security or BLE bonding/permission fix |
| 📝 | `docs` | Documentation or `protocol/spec.md` updates |
| 🔧 | `chore` | Build scripts, Gradle/SPM config, `LaunchAgent` |
| 🔥 | `chore` | Remove dead code or files |

**Examples:**
```text
✨ feat(macos): implement CoreAudio passive playback listener with 400ms debounce
⚡️ perf(android): switch BLE GATT link to CONNECTION_PRIORITY_LOW_POWER
🧪 test(protocol): add cross-platform hex vectors for 6-byte handoff frames
📝 docs(architecture): record Phase 0 IOBluetooth spike results for Galaxy Buds
```

---

## 📋 Pull Request Guidelines

### PR Title Format

```text
<gitmoji> <type>(scope): Short imperative description (≤72 chars)
```

### PR Description Template

```markdown
## Type of change
- [ ] 🐛 Bug fix
- [ ] ✨ New feature
- [ ] ⚡️ Performance / battery improvement
- [ ] 💥 Breaking protocol change
- [ ] 📝 Documentation update

## Platforms touched
- [ ] macOS (`macos/`)
- [ ] Android (`android/`)
- [ ] Protocol (`protocol/spec.md`)

## 📝 What & Why
<!-- Describe WHAT changed and WHY. Link to docs/ guides if applicable. -->

## 📊 Resource Impact
- macOS RAM / Idle CPU: <!-- e.g., 11.4 MB / 0.0% -->
- Android battery / wakeup behavior: <!-- e.g., hardware-offloaded presence only -->

## 🔍 How to Test
1. `cd macos && swift test`
2. `cd android && ./gradlew testDebugUnitTest`
3. Hardware verification steps (if applicable)

## ✅ Checklist
- [ ] Unit tests added / updated and passing on touched platforms
- [ ] No polling loops, WakeLocks, or continuous BLE scans introduced
- [ ] No personal MAC addresses, keys, or secrets committed
- [ ] `protocol/spec.md` updated if BLE frames/UUIDs changed
- [ ] `docs/<slug>.md` added/updated for significant changes
```

---

## 🚀 Build & Verification Reference

### macOS

```bash
# Build & run unit tests
cd macos && swift build && swift test

# Release build (check binary size & memory footprint)
cd macos && swift build -c release
```

### Android

```bash
# Run unit tests
cd android && ./gradlew testDebugUnitTest

# Build debug APK
cd android && ./gradlew assembleDebug

# Check lint issues
cd android && ./gradlew lintDebug
```

---

## 🚫 What Agents Must Never Do

- ❌ **Never copy or reuse code from `seuil/`** (GPLv3 license + Linux-only BlueZ/`0x0075` design).
- ❌ **Never attempt to broadcast `CBAdvertisementDataManufacturerDataKey` in macOS `CoreBluetooth`** — Apple blocks it silently.
- ❌ **Never introduce Electron, WebViews, Python, or Node.js** into the macOS runtime.
- ❌ **Never add polling loops** (`Timer`, shell commands like `blueutil` on an interval, or continuous BLE `startScan()` on Android).
- ❌ **Never acquire Android `WakeLock`s** or keep audio listeners registered when the Mac is disconnected.
- ❌ **Never request `INTERNET` or `ACCESS_FINE_LOCATION` permissions** in Android.
- ❌ **Never leave BLE GATT characteristics unencrypted** (always enforce encryption/bonding).
- ❌ **Never commit personal MAC addresses, keystores, certificates, or secrets.**
- ❌ **Never use `print()` or raw `Log.d()` with sensitive data** in production code.
- ❌ **Never remove or skip tests** to make a build pass.
- ❌ **Never change BLE opcodes or framing** without updating `protocol/spec.md` and cross-platform test vectors.
- ❌ **Never ship a significant feature** without a corresponding `docs/<slug>.md` guide.

---

## 📚 References

- [Architecture Guide](docs/architecture-guide.md)
- [Apple CoreBluetooth (`CBPeripheralManager`)](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager)
- [Apple IOBluetooth (`IOBluetoothDevice`)](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice)
- [Apple CoreAudio HAL Properties](https://developer.apple.com/documentation/coreaudio)
- [Android CompanionDeviceManager (Device Presence)](https://developer.android.com/develop/connectivity/bluetooth/companion-device-pairing)
- [Android AudioPlaybackCallback](https://developer.android.com/reference/android/media/AudioManager.AudioPlaybackCallback)
- [Shizuku Developer Guide](https://github.com/RikkaApps/Shizuku-API)
- [Conventional Commits](https://www.conventionalcommits.org/)
- [Gitmoji](https://gitmoji.dev/)
