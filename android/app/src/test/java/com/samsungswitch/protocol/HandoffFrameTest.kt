package com.samsungswitch.protocol

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class HandoffFrameTest {

    @Test
    fun `vector 1 claim media seq 1 matches cross platform hex`() {
        // Arrange
        val frame = HandoffFrame(
            opcode = HandoffOpcode.CLAIM,
            reason = HandoffReason.MEDIA,
            state = PeerState.PLAYING,
            seq = 1
        )
        val expected = byteArrayOf(0x01, 0x01, 0x01, 0x01, 0x01, 0x00)

        // Act
        val encoded = frame.encode()
        val decoded = HandoffFrame.decode(expected)

        // Assert
        assertArrayEquals(expected, encoded)
        assertEquals(frame, decoded)
    }

    @Test
    fun `vector 2 claim call seq 42 matches cross platform hex`() {
        // Arrange
        val frame = HandoffFrame(
            opcode = HandoffOpcode.CLAIM,
            reason = HandoffReason.CALL,
            state = PeerState.IN_CALL,
            seq = 42
        )
        val expected = byteArrayOf(0x01, 0x01, 0x02, 0x02, 0x2A, 0x00)

        // Act
        val encoded = frame.encode()
        val decoded = HandoffFrame.decode(expected)

        // Assert
        assertArrayEquals(expected, encoded)
        assertEquals(frame, decoded)
    }

    @Test
    fun `vector 3 released seq 258 uses little endian`() {
        // Arrange
        val frame = HandoffFrame(
            opcode = HandoffOpcode.RELEASED,
            reason = HandoffReason.NONE,
            state = PeerState.IDLE,
            seq = 258
        )
        val expected = byteArrayOf(0x01, 0x02, 0x00, 0x00, 0x02, 0x01)

        // Act
        val encoded = frame.encode()
        val decoded = HandoffFrame.decode(expected)

        // Assert
        assertArrayEquals(expected, encoded)
        assertEquals(frame, decoded)
    }

    @Test
    fun `vector 4 state sync max uint16 seq 65535`() {
        // Arrange
        val frame = HandoffFrame(
            opcode = HandoffOpcode.STATE_SYNC,
            reason = HandoffReason.NONE,
            state = PeerState.BUDS_CONNECTED,
            seq = 65535
        )
        val expected = byteArrayOf(
            0x01,
            0x03,
            0x00,
            0x03,
            0xFF.toByte(),
            0xFF.toByte()
        )

        // Act
        val encoded = frame.encode()
        val decoded = HandoffFrame.decode(expected)

        // Assert
        assertArrayEquals(expected, encoded)
        assertEquals(frame, decoded)
    }

    @Test
    fun `vector 5 heartbeat ack manual seq 1000`() {
        // Arrange
        val frame = HandoffFrame(
            opcode = HandoffOpcode.HEARTBEAT_ACK,
            reason = HandoffReason.MANUAL,
            state = PeerState.IDLE,
            seq = 1000
        )
        val expected = byteArrayOf(
            0x01,
            0x04,
            0x03,
            0x00,
            0xE8.toByte(),
            0x03
        )

        // Act
        val encoded = frame.encode()
        val decoded = HandoffFrame.decode(expected)

        // Assert
        assertArrayEquals(expected, encoded)
        assertEquals(frame, decoded)
    }

    @Test
    fun `invalid frames throw specific FrameCodecException`() {
        assertThrows(FrameCodecException.InvalidLength::class.java) {
            HandoffFrame.decode(byteArrayOf())
        }
        assertThrows(FrameCodecException.InvalidLength::class.java) {
            HandoffFrame.decode(byteArrayOf(0x01, 0x01, 0x01, 0x01, 0x01))
        }
        assertThrows(FrameCodecException.InvalidLength::class.java) {
            HandoffFrame.decode(byteArrayOf(0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00))
        }
        assertThrows(FrameCodecException.UnsupportedVersion::class.java) {
            HandoffFrame.decode(byteArrayOf(0x02, 0x01, 0x01, 0x01, 0x01, 0x00))
        }
        assertThrows(FrameCodecException.InvalidOpcode::class.java) {
            HandoffFrame.decode(byteArrayOf(0x01, 0x09, 0x00, 0x00, 0x01, 0x00))
        }
        assertThrows(FrameCodecException.InvalidReason::class.java) {
            HandoffFrame.decode(byteArrayOf(0x01, 0x01, 0x09, 0x00, 0x01, 0x00))
        }
        assertThrows(FrameCodecException.InvalidState::class.java) {
            HandoffFrame.decode(byteArrayOf(0x01, 0x01, 0x00, 0x09, 0x01, 0x00))
        }
    }
}
