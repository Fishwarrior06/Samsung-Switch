package com.samsungswitch.ble

import com.samsungswitch.protocol.HandoffFrame
import com.samsungswitch.protocol.HandoffOpcode
import com.samsungswitch.protocol.HandoffReason
import com.samsungswitch.protocol.PeerState
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import io.mockk.verify
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class BleLinkCoordinatorTest {

    @Test
    fun `sendFrame encodes monotonic sequence and updates lastTxSummary`() {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val captured = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(captured)) } returns true
        val coordinator = BleLinkCoordinator { transport }

        // Act
        val firstSent = coordinator.sendFrame(HandoffOpcode.STATE_SYNC, HandoffReason.NONE, PeerState.IDLE)
        val secondSent = coordinator.sendFrame(HandoffOpcode.CLAIM, HandoffReason.MEDIA, PeerState.PLAYING)

        // Assert
        assertTrue(firstSent)
        assertTrue(secondSent)
        assertEquals(1, captured[0].seq)
        assertEquals(2, captured[1].seq)
        assertEquals("Last TX: CLAIM reason=MEDIA state=PLAYING seq=2", coordinator.lastTxSummary.value)
    }

    @Test
    fun `onFrameReceived replies with HEARTBEAT_ACK echoing peer sequence`() {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val ackSlot = slot<HandoffFrame>()
        every { transport.sendFrame(capture(ackSlot)) } returns true
        val coordinator = BleLinkCoordinator { transport }
        val incoming = HandoffFrame(
            opcode = HandoffOpcode.STATE_SYNC,
            reason = HandoffReason.NONE,
            state = PeerState.IDLE,
            seq = 77
        )

        // Act
        coordinator.onFrameReceived(incoming)

        // Assert
        verify(exactly = 1) { transport.sendFrame(any()) }
        assertEquals(HandoffOpcode.HEARTBEAT_ACK, ackSlot.captured.opcode)
        assertEquals(77, ackSlot.captured.seq)
        assertEquals("Last RX: STATE_SYNC reason=NONE state=IDLE seq=77", coordinator.lastRxSummary.value)
    }

    @Test
    fun `onFrameReceived does not echo HEARTBEAT_ACK to prevent ping pong`() {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val coordinator = BleLinkCoordinator { transport }
        val incomingAck = HandoffFrame(
            opcode = HandoffOpcode.HEARTBEAT_ACK,
            reason = HandoffReason.MANUAL,
            state = PeerState.IDLE,
            seq = 9
        )

        // Act
        coordinator.onFrameReceived(incomingAck)

        // Assert
        verify(exactly = 0) { transport.sendFrame(any()) }
        assertEquals("Last RX: HEARTBEAT_ACK reason=MANUAL state=IDLE seq=9", coordinator.lastRxSummary.value)
    }
}
