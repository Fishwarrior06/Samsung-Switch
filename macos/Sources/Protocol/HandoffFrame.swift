import Foundation

public enum HandoffOpcode: UInt8, Sendable, CaseIterable {
    case claim = 0x01
    case released = 0x02
    case stateSync = 0x03
    case heartbeatAck = 0x04

    public var label: String {
        switch self {
        case .claim: return "CLAIM"
        case .released: return "RELEASED"
        case .stateSync: return "STATE_SYNC"
        case .heartbeatAck: return "HEARTBEAT_ACK"
        }
    }
}

public enum HandoffReason: UInt8, Sendable, CaseIterable {
    case none = 0x00
    case media = 0x01
    case call = 0x02
    case manual = 0x03

    public var label: String {
        switch self {
        case .none: return "NONE"
        case .media: return "MEDIA"
        case .call: return "CALL"
        case .manual: return "MANUAL"
        }
    }
}

public enum PeerState: UInt8, Sendable, CaseIterable {
    case idle = 0x00
    case playing = 0x01
    case inCall = 0x02
    case budsConnected = 0x03

    public var label: String {
        switch self {
        case .idle: return "IDLE"
        case .playing: return "PLAYING"
        case .inCall: return "IN_CALL"
        case .budsConnected: return "BUDS_CONNECTED"
        }
    }
}

public enum FrameCodecError: Error, Equatable, Sendable {
    case invalidLength(expected: Int, actual: Int)
    case unsupportedVersion(UInt8)
    case invalidOpcode(UInt8)
    case invalidReason(UInt8)
    case invalidState(UInt8)
}

public struct HandoffFrame: Equatable, Sendable {
    public let version: UInt8
    public let opcode: HandoffOpcode
    public let reason: HandoffReason
    public let state: PeerState
    public let seq: UInt16

    public init(
        version: UInt8 = ProtocolConstants.protocolVersion,
        opcode: HandoffOpcode,
        reason: HandoffReason,
        state: PeerState,
        seq: UInt16
    ) {
        self.version = version
        self.opcode = opcode
        self.reason = reason
        self.state = state
        self.seq = seq
    }

    public func encode() -> Data {
        var bytes = [UInt8](repeating: 0, count: ProtocolConstants.frameLength)
        bytes[0] = version
        bytes[1] = opcode.rawValue
        bytes[2] = reason.rawValue
        bytes[3] = state.rawValue
        bytes[4] = UInt8(seq & 0x00FF)
        bytes[5] = UInt8((seq >> 8) & 0x00FF)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> HandoffFrame {
        guard data.count == ProtocolConstants.frameLength else {
            throw FrameCodecError.invalidLength(
                expected: ProtocolConstants.frameLength,
                actual: data.count
            )
        }

        let bytes = [UInt8](data)
        let version = bytes[0]
        guard version == ProtocolConstants.protocolVersion else {
            throw FrameCodecError.unsupportedVersion(version)
        }

        guard let opcode = HandoffOpcode(rawValue: bytes[1]) else {
            throw FrameCodecError.invalidOpcode(bytes[1])
        }
        guard let reason = HandoffReason(rawValue: bytes[2]) else {
            throw FrameCodecError.invalidReason(bytes[2])
        }
        guard let state = PeerState(rawValue: bytes[3]) else {
            throw FrameCodecError.invalidState(bytes[3])
        }

        let seq = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        return HandoffFrame(
            version: version,
            opcode: opcode,
            reason: reason,
            state: state,
            seq: seq
        )
    }

    public var summary: String {
        "\(opcode.label) reason=\(reason.label) state=\(state.label) seq=\(seq)"
    }
}
