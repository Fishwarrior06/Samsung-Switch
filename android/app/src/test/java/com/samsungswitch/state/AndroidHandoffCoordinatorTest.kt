package com.samsungswitch.state

import com.samsungswitch.ble.BleClientTransport
import com.samsungswitch.ble.BleLinkCoordinator
import com.samsungswitch.bluetooth.BudsConnector
import com.samsungswitch.protocol.HandoffFrame
import com.samsungswitch.protocol.HandoffOpcode
import com.samsungswitch.protocol.HandoffReason
import com.samsungswitch.protocol.PeerState
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidHandoffCoordinatorTest {

    @Test
    fun `short local media below debounce does not send CLAIM`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            mediaDebounceMs = 400L,
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onLocalMediaPlayingChanged(true)
        advanceTimeBy(150L)
        coordinator.onLocalMediaPlayingChanged(false)
        advanceUntilIdle()

        // Assert
        verify(exactly = 0) { transport.sendFrame(any()) }
    }

    @Test
    fun `sustained local media after 400ms sends CLAIM and RELEASED triggers Shizuku connect`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val sentFrames = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(sentFrames)) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            mediaDebounceMs = 400L,
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onLocalMediaPlayingChanged(true)
        advanceTimeBy(450L)
        advanceUntilIdle()

        // Assert CLAIM sent
        assertEquals(1, sentFrames.size)
        assertEquals(HandoffOpcode.CLAIM, sentFrames[0].opcode)
        assertEquals(HandoffReason.MEDIA, sentFrames[0].reason)

        // Act: Mac replies RELEASED
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.RELEASED,
                reason = HandoffReason.MEDIA,
                state = PeerState.IDLE,
                seq = 1
            )
        )
        advanceUntilIdle()

        // Assert BudsConnector invoked
        coVerify(exactly = 1) { budsConnector.connectBuds() }
        assertEquals(AndroidOwnership.PHONE_ACTIVE, coordinator.ownership.value)
    }

    @Test
    fun `incoming call triggers 0ms debounce CLAIM(CALL) and rejects Mac media CLAIM`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val sentFrames = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(sentFrames)) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns true
        var pausedCount = 0
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = { pausedCount++ },
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act: Call starts
        coordinator.onCallActiveChanged(true)
        advanceUntilIdle()

        // Assert immediate CLAIM(CALL) and Shizuku connect
        assertEquals(HandoffOpcode.CLAIM, sentFrames[0].opcode)
        assertEquals(HandoffReason.CALL, sentFrames[0].reason)
        coVerify(exactly = 1) { budsConnector.connectBuds() }

        // Act: Mac attempts media CLAIM while phone is in call
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MEDIA,
                state = PeerState.PLAYING,
                seq = 9
            )
        )

        // Assert: rejected with CALL lock & local audio not paused
        assertEquals(0, pausedCount)
        assertEquals(HandoffOpcode.CLAIM, sentFrames.last().opcode)
        assertEquals(HandoffReason.CALL, sentFrames.last().reason)
    }

    @Test
    fun `Mac CLAIM(MEDIA) pauses local playback when not in call`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns true
        var pausedCount = 0
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = { pausedCount++ },
            dispatcher = StandardTestDispatcher(testScheduler)
        )
        coordinator.onLocalMediaPlayingChanged(true)

        // Act
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MEDIA,
                state = PeerState.PLAYING,
                seq = 5
            )
        )

        // Assert
        assertEquals(1, pausedCount)
        assertEquals(AndroidOwnership.HANDING_OFF_TO_MAC, coordinator.ownership.value)
    }
}
