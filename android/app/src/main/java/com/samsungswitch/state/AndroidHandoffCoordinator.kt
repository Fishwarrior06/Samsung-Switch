package com.samsungswitch.state

import com.samsungswitch.ble.AppLogger
import com.samsungswitch.ble.BleLinkCoordinator
import com.samsungswitch.bluetooth.BudsConnector
import com.samsungswitch.protocol.HandoffFrame
import com.samsungswitch.protocol.HandoffOpcode
import com.samsungswitch.protocol.HandoffReason
import com.samsungswitch.protocol.PeerState
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class AndroidOwnership {
    IDLE,
    PHONE_ACTIVE,
    MAC_ACTIVE,
    HANDING_OFF_TO_PHONE,
    HANDING_OFF_TO_MAC
}

class AndroidHandoffCoordinator(
    private val bleCoordinator: BleLinkCoordinator,
    private val budsConnector: BudsConnector,
    private val pauseLocalMedia: () -> Unit,
    private val mediaDebounceMs: Long = 400L,
    private val cooldownMs: Long = 2_500L,
    private val nowMsProvider: () -> Long = { System.currentTimeMillis() },
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate
) {
    companion object {
        private const val CATEGORY = "AndroidHandoff"
    }

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var mediaDebounceJob: Job? = null

    private val _ownership = MutableStateFlow(AndroidOwnership.IDLE)
    val ownership: StateFlow<AndroidOwnership> = _ownership.asStateFlow()

    private val _autoSwitchEnabled = MutableStateFlow(true)
    val autoSwitchEnabled: StateFlow<Boolean> = _autoSwitchEnabled.asStateFlow()

    private var isPhoneInCall = false
    private var isLocalMediaPlaying = false
    private var lastHandoffCompletedAtMs: Long? = null

    fun setAutoSwitchEnabled(enabled: Boolean) {
        _autoSwitchEnabled.value = enabled
        if (!enabled) {
            mediaDebounceJob?.cancel()
            mediaDebounceJob = null
        }
    }

    fun onCallActiveChanged(inCall: Boolean) {
        isPhoneInCall = inCall
        if (inCall) {
            // Priority invariant: CALL preempts media with 0 ms debounce.
            mediaDebounceJob?.cancel()
            mediaDebounceJob = null
            _ownership.value = AndroidOwnership.HANDING_OFF_TO_PHONE
            bleCoordinator.sendFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.CALL,
                state = PeerState.IN_CALL
            )
            scope.launch {
                val connected = budsConnector.connectBuds()
                if (connected) {
                    _ownership.value = AndroidOwnership.PHONE_ACTIVE
                    lastHandoffCompletedAtMs = nowMsProvider()
                }
            }
        } else {
            bleCoordinator.sendFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = if (budsConnector.isBudsConnected()) PeerState.BUDS_CONNECTED else PeerState.IDLE
            )
        }
    }

    fun onLocalMediaPlayingChanged(isPlaying: Boolean) {
        isLocalMediaPlaying = isPlaying
        if (!isPlaying) {
            mediaDebounceJob?.cancel()
            mediaDebounceJob = null
            return
        }

        if (!_autoSwitchEnabled.value || isPhoneInCall) return
        if (budsConnector.isBudsConnected() && _ownership.value == AndroidOwnership.PHONE_ACTIVE) {
            return
        }
        if (isInCooldown()) return

        mediaDebounceJob?.cancel()
        mediaDebounceJob = scope.launch {
            delay(mediaDebounceMs)
            if (!isLocalMediaPlaying || !_autoSwitchEnabled.value || isPhoneInCall || isInCooldown()) {
                return@launch
            }
            _ownership.value = AndroidOwnership.HANDING_OFF_TO_PHONE
            bleCoordinator.sendFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MEDIA,
                state = PeerState.PLAYING
            )
            AppLogger.i(CATEGORY, "Sent CLAIM(MEDIA) to Mac; waiting for RELEASED")
        }
    }

    fun onRemoteFrame(frame: HandoffFrame) {
        when (frame.opcode) {
            HandoffOpcode.CLAIM -> {
                if (isPhoneInCall) {
                    bleCoordinator.sendFrame(
                        opcode = HandoffOpcode.CLAIM,
                        reason = HandoffReason.CALL,
                        state = PeerState.IN_CALL
                    )
                    return
                }
                if (frame.reason == HandoffReason.MEDIA && (!_autoSwitchEnabled.value || isInCooldown())) {
                    return
                }
                mediaDebounceJob?.cancel()
                mediaDebounceJob = null
                if (isLocalMediaPlaying) {
                    pauseLocalMedia()
                }
                _ownership.value = AndroidOwnership.HANDING_OFF_TO_MAC
            }

            HandoffOpcode.RELEASED -> {
                mediaDebounceJob?.cancel()
                mediaDebounceJob = null
                _ownership.value = AndroidOwnership.HANDING_OFF_TO_PHONE
                scope.launch {
                    val connected = budsConnector.connectBuds()
                    _ownership.value = if (connected) AndroidOwnership.PHONE_ACTIVE else AndroidOwnership.IDLE
                    lastHandoffCompletedAtMs = nowMsProvider()
                }
            }

            HandoffOpcode.STATE_SYNC -> {
                if (frame.state == PeerState.BUDS_CONNECTED) {
                    _ownership.value = AndroidOwnership.MAC_ACTIVE
                    lastHandoffCompletedAtMs = nowMsProvider()
                } else if (frame.state == PeerState.IDLE &&
                    _ownership.value == AndroidOwnership.HANDING_OFF_TO_MAC
                ) {
                    _ownership.value = if (budsConnector.isBudsConnected()) {
                        AndroidOwnership.PHONE_ACTIVE
                    } else {
                        AndroidOwnership.IDLE
                    }
                }
            }

            HandoffOpcode.HEARTBEAT_ACK -> Unit
        }
    }

    private fun isInCooldown(): Boolean {
        val last = lastHandoffCompletedAtMs ?: return false
        return (nowMsProvider() - last) < cooldownMs
    }
}
