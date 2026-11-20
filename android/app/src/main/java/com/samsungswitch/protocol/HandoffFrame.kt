package com.samsungswitch.protocol

enum class HandoffOpcode(val code: Byte) {
    CLAIM(0x01),
    RELEASED(0x02),
    STATE_SYNC(0x03),
    HEARTBEAT_ACK(0x04);

    companion object {
        fun fromByte(value: Byte): HandoffOpcode? = entries.firstOrNull { it.code == value }
    }
}

enum class HandoffReason(val code: Byte) {
    NONE(0x00),
    MEDIA(0x01),
    CALL(0x02),
    MANUAL(0x03);

    companion object {
        fun fromByte(value: Byte): HandoffReason? = entries.firstOrNull { it.code == value }
    }
}

enum class PeerState(val code: Byte) {
    IDLE(0x00),
    PLAYING(0x01),
    IN_CALL(0x02),
    BUDS_CONNECTED(0x03);

    companion object {
        fun fromByte(value: Byte): PeerState? = entries.firstOrNull { it.code == value }
    }
}

sealed class FrameCodecException(message: String) : IllegalArgumentException(message) {
    class InvalidLength(expected: Int, actual: Int) :
        FrameCodecException("Invalid frame length: expected $expected, got $actual")

    class UnsupportedVersion(version: Int) :
        FrameCodecException("Unsupported protocol version: $version")

    class InvalidOpcode(raw: Int) :
        FrameCodecException("Unknown opcode: $raw")

    class InvalidReason(raw: Int) :
        FrameCodecException("Unknown reason: $raw")

    class InvalidState(raw: Int) :
        FrameCodecException("Unknown state: $raw")
}

data class HandoffFrame(
    val version: Byte = ProtocolConstants.PROTOCOL_VERSION,
    val opcode: HandoffOpcode,
    val reason: HandoffReason,
    val state: PeerState,
    val seq: Int
) {
    init {
        require(seq in 0..0xFFFF) { "Sequence number must fit in uint16 (0..65535): $seq" }
    }

    fun encode(): ByteArray {
        val bytes = ByteArray(ProtocolConstants.FRAME_LENGTH)
        bytes[0] = version
        bytes[1] = opcode.code
        bytes[2] = reason.code
        bytes[3] = state.code
        bytes[4] = (seq and 0xFF).toByte()
        bytes[5] = ((seq ushr 8) and 0xFF).toByte()
        return bytes
    }

    fun summary(): String {
        return "${opcode.name} reason=${reason.name} state=${state.name} seq=$seq"
    }

    companion object {
        fun decode(bytes: ByteArray): HandoffFrame {
            if (bytes.size != ProtocolConstants.FRAME_LENGTH) {
                throw FrameCodecException.InvalidLength(ProtocolConstants.FRAME_LENGTH, bytes.size)
            }

            val version = bytes[0]
            if (version != ProtocolConstants.PROTOCOL_VERSION) {
                throw FrameCodecException.UnsupportedVersion(version.toInt() and 0xFF)
            }

            val opcode = HandoffOpcode.fromByte(bytes[1])
                ?: throw FrameCodecException.InvalidOpcode(bytes[1].toInt() and 0xFF)
            val reason = HandoffReason.fromByte(bytes[2])
                ?: throw FrameCodecException.InvalidReason(bytes[2].toInt() and 0xFF)
            val state = PeerState.fromByte(bytes[3])
                ?: throw FrameCodecException.InvalidState(bytes[3].toInt() and 0xFF)

            val low = bytes[4].toInt() and 0xFF
            val high = bytes[5].toInt() and 0xFF
            val seq = low or (high shl 8)

            return HandoffFrame(
                version = version,
                opcode = opcode,
                reason = reason,
                state = state,
                seq = seq
            )
        }
    }
}
