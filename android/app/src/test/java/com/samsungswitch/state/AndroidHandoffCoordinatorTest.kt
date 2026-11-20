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
import kotlinx.coroutines.test.runCurrent
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
        coEvery { budsConnector.disconnectBuds() } returns true
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
        coEvery { budsConnector.disconnectBuds() } returns true
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
        runCurrent()

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
        runCurrent()

        // Assert BudsConnector invoked and awaiting real audio output connection
        coVerify(exactly = 1) { budsConnector.connectBuds() }
        assertEquals(AndroidOwnership.HANDING_OFF_TO_PHONE, coordinator.ownership.value)

        // Act: AudioDeviceCallback observes Buds connected
        every { budsConnector.isBudsConnected() } returns true
        coordinator.onBudsConnectionChanged(true)

        // Assert
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
        coEvery { budsConnector.disconnectBuds() } returns true
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
    fun `Mac CLAIM(MEDIA) pauses local playback, disconnects Buds, and sends RELEASED`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val sentFrames = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(sentFrames)) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns true
        var pausedCount = 0
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = { pausedCount++ },
            handoffTimeoutMs = 7_000L,
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
        advanceTimeBy(50L)

        // Assert
        assertEquals(1, pausedCount)
        assertEquals(AndroidOwnership.HANDING_OFF_TO_MAC, coordinator.ownership.value)
        coVerify(exactly = 1) { budsConnector.disconnectBuds() }
        assertEquals(HandoffOpcode.RELEASED, sentFrames.last().opcode)
        assertEquals(HandoffReason.MEDIA, sentFrames.last().reason)
    }

    @Test
    fun `HANDING_OFF_TO_MAC resets cleanly on timeout when Mac never responds`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.disconnectBuds() } returns false
        every { budsConnector.isBudsConnected() } returns false
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            handoffTimeoutMs = 7_000L,
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MANUAL,
                state = PeerState.IDLE,
                seq = 12
            )
        )
        advanceTimeBy(1_000L)
        assertEquals(AndroidOwnership.HANDING_OFF_TO_MAC, coordinator.ownership.value)

        advanceTimeBy(6_500L)
        advanceUntilIdle()

        // Assert
        assertEquals(AndroidOwnership.IDLE, coordinator.ownership.value)
    }

    @Test
    fun `STATE_SYNC(IDLE) clears HANDING_OFF_TO_MAC when Mac pull fails`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns true
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MANUAL,
                state = PeerState.IDLE,
                seq = 13
            )
        )
        advanceTimeBy(50L)
        assertEquals(AndroidOwnership.HANDING_OFF_TO_MAC, coordinator.ownership.value)

        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.IDLE,
                seq = 14
            )
        )
        advanceUntilIdle()

        // Assert
        assertEquals(AndroidOwnership.PHONE_ACTIVE, coordinator.ownership.value)
    }

    @Test
    fun `call claim fires Phone handoff banner`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns true
        val banners = mutableListOf<Pair<String, HandoffReason>>()
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            onHandoffBanner = { destination, reason -> banners.add(destination to reason) },
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onCallActiveChanged(true)
        advanceUntilIdle()

        // Assert
        assertEquals(listOf("Phone" to HandoffReason.CALL), banners)
    }

    @Test
    fun `remote RELEASED connects Buds and fires Phone handoff banner`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val banners = mutableListOf<Pair<String, HandoffReason>>()
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            onHandoffBanner = { destination, reason -> banners.add(destination to reason) },
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.RELEASED,
                reason = HandoffReason.MEDIA,
                state = PeerState.IDLE,
                seq = 20
            )
        )
        runCurrent()

        // Assert: still waiting for real Buds connection before showing banner
        assertEquals(AndroidOwnership.HANDING_OFF_TO_PHONE, coordinator.ownership.value)
        assertEquals(emptyList<Pair<String, HandoffReason>>(), banners)

        // Act: AudioDeviceCallback confirms Buds connected
        every { budsConnector.isBudsConnected() } returns true
        coordinator.onBudsConnectionChanged(true)

        // Assert
        assertEquals(AndroidOwnership.PHONE_ACTIVE, coordinator.ownership.value)
        assertEquals(listOf("Phone" to HandoffReason.MEDIA), banners)
    }

    @Test
    fun `remote STATE_SYNC(BUDS_CONNECTED) fires Mac handoff banner on transition into MAC_ACTIVE`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val banners = mutableListOf<Pair<String, HandoffReason>>()
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            onHandoffBanner = { destination, reason -> banners.add(destination to reason) },
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.MEDIA,
                state = PeerState.BUDS_CONNECTED,
                seq = 21
            )
        )
        advanceUntilIdle()

        // Assert
        assertEquals(AndroidOwnership.MAC_ACTIVE, coordinator.ownership.value)
        assertEquals(listOf("Mac" to HandoffReason.MEDIA), banners)
    }

    @Test
    fun `local media bounce during cooldown is dropped and fresh playback after cooldown claims Buds`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val sentFrames = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(sentFrames)) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            mediaDebounceMs = 400L,
            cooldownMs = 2_500L,
            nowMsProvider = { testScheduler.currentTime },
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Move to HANDING_OFF_TO_MAC then settle MAC_ACTIVE at t=50ms -> cooldown until 2550ms
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MANUAL,
                state = PeerState.IDLE,
                seq = 1
            )
        )
        advanceTimeBy(50L)
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.BUDS_CONNECTED,
                seq = 2
            )
        )
        advanceUntilIdle()
        sentFrames.clear()

        // Act: bounce starts at t=550ms (inside 2500ms cooldown) -> dropped completely
        advanceTimeBy(500L)
        coordinator.onLocalMediaPlayingChanged(true)
        advanceTimeBy(2_200L)
        advanceUntilIdle()

        // Assert: dropped bounce never triggers CLAIM after cooldown expires
        assertEquals(0, sentFrames.count { it.opcode == HandoffOpcode.CLAIM })

        // Act: fresh playback after cooldown expires claims Buds cleanly
        coordinator.onLocalMediaPlayingChanged(false)
        coordinator.onLocalMediaPlayingChanged(true)
        advanceTimeBy(450L)
        advanceUntilIdle()

        // Assert
        assertEquals(1, sentFrames.count { it.opcode == HandoffOpcode.CLAIM && it.reason == HandoffReason.MEDIA })
    }

    @Test
    fun `cold-start STATE_SYNC(NONE, BUDS_CONNECTED) from IDLE syncs MAC_ACTIVE without banner or cooldown`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val sentFrames = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(sentFrames)) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val banners = mutableListOf<Pair<String, HandoffReason>>()
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            mediaDebounceMs = 400L,
            cooldownMs = 2_500L,
            nowMsProvider = { testScheduler.currentTime },
            onHandoffBanner = { destination, reason -> banners.add(destination to reason) },
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act: cold-start sync from Mac
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.BUDS_CONNECTED,
                seq = 1
            )
        )
        advanceUntilIdle()

        // Assert: synced to MAC_ACTIVE without banner
        assertEquals(AndroidOwnership.MAC_ACTIVE, coordinator.ownership.value)
        assertEquals(emptyList<Pair<String, HandoffReason>>(), banners)

        // Act: immediately start local playback (must not wait 2.5s cooldown)
        coordinator.onLocalMediaPlayingChanged(true)
        advanceTimeBy(450L)
        advanceUntilIdle()

        // Assert
        assertEquals(1, sentFrames.count { it.opcode == HandoffOpcode.CLAIM && it.reason == HandoffReason.MEDIA })
    }

    @Test
    fun `STATE_SYNC(NONE, BUDS_CONNECTED) after HANDING_OFF_TO_MAC settles MAC_ACTIVE and fires Mac banner`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val banners = mutableListOf<Pair<String, HandoffReason>>()
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            onHandoffBanner = { destination, reason -> banners.add(destination to reason) },
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MANUAL,
                state = PeerState.IDLE,
                seq = 30
            )
        )
        advanceTimeBy(50L)
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.BUDS_CONNECTED,
                seq = 31
            )
        )
        advanceUntilIdle()

        // Assert
        assertEquals(AndroidOwnership.MAC_ACTIVE, coordinator.ownership.value)
        assertEquals(listOf("Mac" to HandoffReason.MEDIA), banners)
    }

    @Test
    fun `remote RELEASED when async connectBuds never connects times out to IDLE without PHONE_ACTIVE or banner`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val sentFrames = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(sentFrames)) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.connectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val banners = mutableListOf<Pair<String, HandoffReason>>()
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            handoffTimeoutMs = 2_000L,
            onHandoffBanner = { destination, reason -> banners.add(destination to reason) },
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Act
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.RELEASED,
                reason = HandoffReason.MEDIA,
                state = PeerState.IDLE,
                seq = 40
            )
        )
        advanceTimeBy(500L)
        assertEquals(AndroidOwnership.HANDING_OFF_TO_PHONE, coordinator.ownership.value)

        advanceTimeBy(1_600L)
        advanceUntilIdle()

        // Assert
        assertEquals(AndroidOwnership.IDLE, coordinator.ownership.value)
        assertEquals(emptyList<Pair<String, HandoffReason>>(), banners)
        assertEquals(HandoffOpcode.STATE_SYNC, sentFrames.last().opcode)
        assertEquals(PeerState.IDLE, sentFrames.last().state)
    }

    @Test
    fun `onBudsConnectionChanged(false) clears PHONE_ACTIVE and notifies Mac STATE_SYNC(IDLE)`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val sentFrames = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(sentFrames)) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        every { budsConnector.isBudsConnected() } returns true
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            dispatcher = StandardTestDispatcher(testScheduler)
        )
        coordinator.onBleConnected(budsConnected = true)
        assertEquals(AndroidOwnership.PHONE_ACTIVE, coordinator.ownership.value)

        // Act
        every { budsConnector.isBudsConnected() } returns false
        coordinator.onBudsConnectionChanged(false)

        // Assert
        assertEquals(AndroidOwnership.IDLE, coordinator.ownership.value)
        assertEquals(HandoffOpcode.STATE_SYNC, sentFrames.last().opcode)
        assertEquals(PeerState.IDLE, sentFrames.last().state)
    }

    @Test
    fun `local media during HANDING_OFF_TO_MAC is ignored to prevent glare race`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        val sentFrames = mutableListOf<HandoffFrame>()
        every { transport.sendFrame(capture(sentFrames)) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        coEvery { budsConnector.disconnectBuds() } returns true
        every { budsConnector.isBudsConnected() } returns false
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            mediaDebounceMs = 400L,
            dispatcher = StandardTestDispatcher(testScheduler)
        )

        // Enter HANDING_OFF_TO_MAC
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MEDIA,
                state = PeerState.PLAYING,
                seq = 50
            )
        )
        advanceTimeBy(50L)
        assertEquals(AndroidOwnership.HANDING_OFF_TO_MAC, coordinator.ownership.value)
        sentFrames.clear()

        // Act: local media starts while Mac pull is still in progress
        coordinator.onLocalMediaPlayingChanged(true)
        advanceTimeBy(500L)
        runCurrent()

        // Assert: no glare CLAIM sent
        assertEquals(0, sentFrames.count { it.opcode == HandoffOpcode.CLAIM })
        assertEquals(AndroidOwnership.HANDING_OFF_TO_MAC, coordinator.ownership.value)
    }

    @Test
    fun `remote STATE_SYNC(IDLE) clears stale MAC_ACTIVE`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        every { budsConnector.isBudsConnected() } returns false
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            dispatcher = StandardTestDispatcher(testScheduler)
        )
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.BUDS_CONNECTED,
                seq = 60
            )
        )
        assertEquals(AndroidOwnership.MAC_ACTIVE, coordinator.ownership.value)

        // Act
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.IDLE,
                seq = 61
            )
        )

        // Assert
        assertEquals(AndroidOwnership.IDLE, coordinator.ownership.value)
    }

    @Test
    fun `onBleConnected reconciles stale PHONE_ACTIVE to IDLE when Buds are disconnected`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        every { budsConnector.isBudsConnected() } returns false
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            dispatcher = StandardTestDispatcher(testScheduler)
        )
        coordinator.onBleConnected(budsConnected = true)
        assertEquals(AndroidOwnership.PHONE_ACTIVE, coordinator.ownership.value)

        // Act
        coordinator.onBleConnected(budsConnected = false)

        // Assert
        assertEquals(AndroidOwnership.IDLE, coordinator.ownership.value)
    }

    @Test
    fun `cold-start STATE_SYNC(NONE, BUDS_CONNECTED) from stale PHONE_ACTIVE reconciles to MAC_ACTIVE without phantom banner`() = runTest {
        // Arrange
        val transport = mockk<BleClientTransport>()
        every { transport.sendFrame(any()) } returns true
        val bleCoordinator = BleLinkCoordinator { transport }
        val budsConnector = mockk<BudsConnector>()
        every { budsConnector.isBudsConnected() } returns false
        val banners = mutableListOf<Pair<String, HandoffReason>>()
        val coordinator = AndroidHandoffCoordinator(
            bleCoordinator = bleCoordinator,
            budsConnector = budsConnector,
            pauseLocalMedia = {},
            onHandoffBanner = { destination, reason -> banners.add(destination to reason) },
            dispatcher = StandardTestDispatcher(testScheduler)
        )
        coordinator.onBleConnected(budsConnected = true)
        assertEquals(AndroidOwnership.PHONE_ACTIVE, coordinator.ownership.value)

        // Act: Mac reports BUDS_CONNECTED on BLE reconnect with reason NONE
        coordinator.onRemoteFrame(
            HandoffFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.BUDS_CONNECTED,
                seq = 70
            )
        )

        // Assert
        assertEquals(AndroidOwnership.MAC_ACTIVE, coordinator.ownership.value)
        assertEquals(emptyList<Pair<String, HandoffReason>>(), banners)
    }
}
