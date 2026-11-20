import Foundation
import Testing
@testable import SamsungSwitchCore

@Suite("Protocol Frame Cross-Platform Vectors")
struct ProtocolTests {
    @Test("Vector 1: Mac claims Buds for media (seq=1)")
    func vector1_claimMedia() throws {
        // Arrange
        let frame = HandoffFrame(opcode: .claim, reason: .media, state: .playing, seq: 1)
        let expectedBytes = Data([0x01, 0x01, 0x01, 0x01, 0x01, 0x00])

        // Act
        let encoded = frame.encode()
        let decoded = try HandoffFrame.decode(expectedBytes)

        // Assert
        #expect(encoded == expectedBytes)
        #expect(decoded == frame)
    }

    @Test("Vector 2: Phone claims Buds for call (seq=42)")
    func vector2_claimCall() throws {
        // Arrange
        let frame = HandoffFrame(opcode: .claim, reason: .call, state: .inCall, seq: 42)
        let expectedBytes = Data([0x01, 0x01, 0x02, 0x02, 0x2A, 0x00])

        // Act
        let encoded = frame.encode()
        let decoded = try HandoffFrame.decode(expectedBytes)

        // Assert
        #expect(encoded == expectedBytes)
        #expect(decoded == frame)
    }

    @Test("Vector 3: Mac released Buds (seq=258 little-endian)")
    func vector3_releasedLittleEndian() throws {
        // Arrange
        let frame = HandoffFrame(opcode: .released, reason: .none, state: .idle, seq: 258)
        let expectedBytes = Data([0x01, 0x02, 0x00, 0x00, 0x02, 0x01])

        // Act
        let encoded = frame.encode()
        let decoded = try HandoffFrame.decode(expectedBytes)

        // Assert
        #expect(encoded == expectedBytes)
        #expect(decoded == frame)
    }

    @Test("Vector 4: State sync with Buds connected (seq=65535)")
    func vector4_stateSyncMaxSeq() throws {
        // Arrange
        let frame = HandoffFrame(opcode: .stateSync, reason: .none, state: .budsConnected, seq: 65535)
        let expectedBytes = Data([0x01, 0x03, 0x00, 0x03, 0xFF, 0xFF])

        // Act
        let encoded = frame.encode()
        let decoded = try HandoffFrame.decode(expectedBytes)

        // Assert
        #expect(encoded == expectedBytes)
        #expect(decoded == frame)
    }

    @Test("Vector 5: Heartbeat ACK manual (seq=1000)")
    func vector5_heartbeatAck() throws {
        // Arrange
        let frame = HandoffFrame(opcode: .heartbeatAck, reason: .manual, state: .idle, seq: 1000)
        let expectedBytes = Data([0x01, 0x04, 0x03, 0x00, 0xE8, 0x03])

        // Act
        let encoded = frame.encode()
        let decoded = try HandoffFrame.decode(expectedBytes)

        // Assert
        #expect(encoded == expectedBytes)
        #expect(decoded == frame)
    }

    @Test("Invalid frames are rejected with specific codec errors")
    func invalidFrames_rejected() {
        #expect(throws: FrameCodecError.invalidLength(expected: 6, actual: 0)) {
            try HandoffFrame.decode(Data())
        }
        #expect(throws: FrameCodecError.invalidLength(expected: 6, actual: 5)) {
            try HandoffFrame.decode(Data([0x01, 0x01, 0x01, 0x01, 0x01]))
        }
        #expect(throws: FrameCodecError.invalidLength(expected: 6, actual: 7)) {
            try HandoffFrame.decode(Data([0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00]))
        }
        #expect(throws: FrameCodecError.unsupportedVersion(0x02)) {
            try HandoffFrame.decode(Data([0x02, 0x01, 0x01, 0x01, 0x01, 0x00]))
        }
        #expect(throws: FrameCodecError.invalidOpcode(0x09)) {
            try HandoffFrame.decode(Data([0x01, 0x09, 0x00, 0x00, 0x01, 0x00]))
        }
        #expect(throws: FrameCodecError.invalidReason(0x09)) {
            try HandoffFrame.decode(Data([0x01, 0x01, 0x09, 0x00, 0x01, 0x00]))
        }
        #expect(throws: FrameCodecError.invalidState(0x09)) {
            try HandoffFrame.decode(Data([0x01, 0x01, 0x00, 0x09, 0x01, 0x00]))
        }
    }
}
