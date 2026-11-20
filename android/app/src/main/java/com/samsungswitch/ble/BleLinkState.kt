package com.samsungswitch.ble

import com.samsungswitch.protocol.HandoffFrame
import com.samsungswitch.protocol.HandoffOpcode
import com.samsungswitch.protocol.HandoffReason
import com.samsungswitch.protocol.PeerState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.atomic.AtomicInteger

sealed class BleLinkState(val displayText: String) {
    data object Disconnected : BleLinkState("Disconnected")
    data object Associating : BleLinkState("Associating Mac...")
    data object Connecting : BleLinkState("Connecting GATT...")
    data object Bonding : BleLinkState("Pairing / Bonding...")
    data object ConnectedLowPower : BleLinkState("Connected (LOW_POWER)")
    data class Error(val reason: String) : BleLinkState("Error: $reason")
}

interface BleClientTransport {
    fun connect(address: String, autoConnect: Boolean = true)
    fun disconnect()
    fun sendFrame(frame: HandoffFrame): Boolean
}

class BleLinkCoordinator(
    private val transportProvider: () -> BleClientTransport
) {
    private val seqCounter = AtomicInteger(0)

    private val _linkState = MutableStateFlow<BleLinkState>(BleLinkState.Disconnected)
    val linkState: StateFlow<BleLinkState> = _linkState.asStateFlow()

    private val _lastRxSummary = MutableStateFlow("Last RX: —")
    val lastRxSummary: StateFlow<String> = _lastRxSummary.asStateFlow()

    private val _lastTxSummary = MutableStateFlow("Last TX: —")
    val lastTxSummary: StateFlow<String> = _lastTxSummary.asStateFlow()

    private val _associatedMacPresent = MutableStateFlow(false)
    val associatedMacPresent: StateFlow<Boolean> = _associatedMacPresent.asStateFlow()

    var onRemoteFrameListener: ((HandoffFrame) -> Unit)? = null
    var onLinkStateChangedListener: ((BleLinkState) -> Unit)? = null

    fun setAssociatedMacPresent(present: Boolean) {
        _associatedMacPresent.value = present
    }

    fun updateLinkState(state: BleLinkState) {
        _linkState.value = state
        onLinkStateChangedListener?.invoke(state)
    }

    fun nextSequence(): Int {
        return seqCounter.updateAndGet { current ->
            (current + 1) and 0xFFFF
        }
    }

    fun sendFrame(
        opcode: HandoffOpcode,
        reason: HandoffReason,
        state: PeerState
    ): Boolean {
        val frame = HandoffFrame(
            opcode = opcode,
            reason = reason,
            state = state,
            seq = nextSequence()
        )
        val sent = transportProvider().sendFrame(frame)
        if (sent) {
            _lastTxSummary.value = "Last TX: ${frame.summary()}"
        }
        return sent
    }

    fun onFrameReceived(frame: HandoffFrame) {
        _lastRxSummary.value = "Last RX: ${frame.summary()}"
        onRemoteFrameListener?.invoke(frame)
        if (frame.opcode == HandoffOpcode.STATE_SYNC) {
            val ack = HandoffFrame(
                opcode = HandoffOpcode.HEARTBEAT_ACK,
                reason = frame.reason,
                state = PeerState.IDLE,
                seq = frame.seq
            )
            if (transportProvider().sendFrame(ack)) {
                _lastTxSummary.value = "Last TX: ${ack.summary()}"
            }
        }
    }
}
