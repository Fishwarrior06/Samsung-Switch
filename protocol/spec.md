# Samsung Switch BLE GATT Protocol Specification (v1)

> **Single source of truth** for BLE GATT UUIDs, permissions, binary framing, and cross-platform test vectors.
> Both `macos/Sources/Protocol/` (Swift) and `android/app/src/main/java/com/samsungswitch/protocol/` (Kotlin) must match this document byte-for-byte.

---

## 1. GATT Profile & Security

### Roles
- **macOS (`CBPeripheralManager`):** BLE GATT Server & Peripheral. Advertises `SERVICE_UUID` via `CBAdvertisementDataServiceUUIDsKey`.
- **Android (`CompanionDeviceManager` + `BluetoothGatt`):** BLE GATT Central & Client. Uses `startObservingDevicePresence` + `connectGatt(..., autoConnect = true, TRANSPORT_LE)` + `CONNECTION_PRIORITY_LOW_POWER`.

### UUIDs (128-bit Custom UUIDs)
| Symbol | UUID | Role |
|---|---|---|
| `SERVICE_UUID` | `E4A10001-7C3B-4B2A-9D1E-5A8F00000001` | Primary Samsung Switch GATT Service |
| `TX_TO_MAC_UUID` | `E4A10002-7C3B-4B2A-9D1E-5A8F00000001` | Android → Mac commands |
| `TX_TO_PHONE_UUID` | `E4A10003-7C3B-4B2A-9D1E-5A8F00000001` | Mac → Android commands & status |
| `CCCD_UUID` | `00002902-0000-1000-8000-00805F9B34FB` | Standard Client Characteristic Configuration Descriptor |

### Characteristic Properties & Encryption Requirements
BLE Bonding (link-layer encryption) is **mandatory**:

| Characteristic | Properties | Permissions |
|---|---|---|
| `TX_TO_MAC` | `Write` (with response) | Encrypted write required (`.writeEncryptionRequired` on macOS) |
| `TX_TO_PHONE` | `Read`, `Notify` | Encrypted read required (`.readEncryptionRequired` on macOS) |

> Unbonded writes/reads/CCCD operations must fail with insufficient authentication/encryption so OS-level BLE Bonding is enforced before any frame is accepted.

---

## 2. Binary Frame Format (Fixed 6 Bytes)

Every message exchanged on `TX_TO_MAC` and `TX_TO_PHONE` is an exact **6-byte** binary frame:

| Byte Offset | Size | Field | Type | Description |
|---|---|---|---|---|
| `0` | 1 | `version` | `uint8` | Protocol version (`0x01`) |
| `1` | 1 | `opcode` | `uint8` | Message opcode |
| `2` | 1 | `reason` | `uint8` | Trigger reason |
| `3` | 1 | `state` | `uint8` | Sender state |
| `4..5` | 2 | `seq` | `uint16` (Little-Endian) | Monotonic sequence number (`0..65535`) for deduplication & ACK |

Frames with `length != 6`, `version != 0x01`, or unknown enum values must be rejected during decoding.

### Field Enums

#### `opcode` (Byte 1)
| Value | Name | Direction | Meaning |
|---|---|---|---|
| `0x01` | `CLAIM` | Bidirectional | Sender claims Buds ownership (Mac or Phone audio/call started) |
| `0x02` | `RELEASED` | Mac → Android | Mac closed the Buds connection (`closeConnection()` completed) |
| `0x03` | `STATE_SYNC` | Bidirectional | Initial/periodic state synchronization upon connect or state change |
| `0x04` | `HEARTBEAT_ACK` | Bidirectional | Link verification / acknowledgment echoing peer `seq` |

#### `reason` (Byte 2)
| Value | Name | Meaning |
|---|---|---|
| `0x00` | `NONE` | No trigger (used with `RELEASED`, `STATE_SYNC`, `HEARTBEAT_ACK`) |
| `0x01` | `MEDIA` | Media playback started |
| `0x02` | `CALL` | Phone/VoIP call started (0 ms debounce priority) |
| `0x03` | `MANUAL` | User manually triggered switch or Phase 1 test command |

#### `state` (Byte 3)
| Value | Name | Meaning |
|---|---|---|
| `0x00` | `IDLE` | Sender is idle |
| `0x01` | `PLAYING` | Sender has active media playback |
| `0x02` | `IN_CALL` | Sender is in an active or ringing call (`CALL_LOCK`) |
| `0x03` | `BUDS_CONNECTED` | Sender currently holds the Buds audio connection |

---

## 3. Cross-Platform Test Vectors

Both `macos/Tests/` and `android/app/src/test/` must verify identical encode/decode results for these canonical hex vectors:

| Case | `version` | `opcode` | `reason` | `state` | `seq` (uint16 LE) | Exact 6-Byte Hex |
|---|---|---|---|---|---|---|
| 1. Mac claims Buds for media (`seq=1`) | `0x01` | `CLAIM (0x01)` | `MEDIA (0x01)` | `PLAYING (0x01)` | `1` (`0x01, 0x00`) | `01 01 01 01 01 00` |
| 2. Phone claims Buds for call (`seq=42`) | `0x01` | `CLAIM (0x01)` | `CALL (0x02)` | `IN_CALL (0x02)` | `42` (`0x2A, 0x00`) | `01 01 02 02 2A 00` |
| 3. Mac released Buds (`seq=258`, LE check) | `0x01` | `RELEASED (0x02)` | `NONE (0x00)` | `IDLE (0x00)` | `258` (`0x02, 0x01`) | `01 02 00 00 02 01` |
| 4. State sync with Buds connected (`seq=65535`) | `0x01` | `STATE_SYNC (0x03)` | `NONE (0x00)` | `BUDS_CONNECTED (0x03)` | `65535` (`0xFF, 0xFF`) | `01 03 00 03 FF FF` |
| 5. Heartbeat ACK manual (`seq=1000`) | `0x01` | `HEARTBEAT_ACK (0x04)` | `MANUAL (0x03)` | `IDLE (0x00)` | `1000` (`0xE8, 0x03`) | `01 04 03 00 E8 03` |

### Invalid Vectors (Must Fail Decode)
- Empty frame: `""` → invalid length
- Truncated frame (5 bytes): `01 01 01 01 01` → invalid length
- Oversized frame (7 bytes): `01 01 01 01 01 00 00` → invalid length
- Unsupported version: `02 01 01 01 01 00` → unsupported version
- Unknown opcode: `01 09 00 00 01 00` → invalid opcode
- Unknown reason: `01 01 09 00 01 00` → invalid reason
- Unknown state: `01 01 00 09 01 00` → invalid state
