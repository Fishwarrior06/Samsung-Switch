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
    private val handoffTimeoutMs: Long = 10_000L,
    private val nowMsProvider: () -> Long = { System.currentTimeMillis() },
    private val onHandoffBanner: (destination: String, reason: HandoffReason) -> Unit = { _, _ -> },
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate
) {
    companion object {
        private const val CATEGORY = "AndroidHandoff"
    }

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private var mediaDebounceJob: Job? = null
    private var handoffTimeoutJob: Job? = null
    private var activeHandoffJob: Job? = null
    private var handoffGeneration: Long = 0L

    private val _ownership = MutableStateFlow(AndroidOwnership.IDLE)
    val ownership: StateFlow<AndroidOwnership> = _ownership.asStateFlow()

    private val _autoSwitchEnabled = MutableStateFlow(true)
    val autoSwitchEnabled: StateFlow<Boolean> = _autoSwitchEnabled.asStateFlow()

    private var isPhoneInCall = false
    private var isLocalMediaPlaying = false
    private var pendingPhoneHandoffReason: HandoffReason? = null
    private var lastHandoffCompletedAtMs: Long? = null
    private var lastBudsDisconnectedAtMs: Long? = null

    fun setAutoSwitchEnabled(enabled: Boolean) {
        _autoSwitchEnabled.value = enabled
        if (!enabled) {
            mediaDebounceJob?.cancel()
            mediaDebounceJob = null
        }
    }

    fun onBleConnected(budsConnected: Boolean) {
        val current = _ownership.value
        if (current != AndroidOwnership.HANDING_OFF_TO_MAC &&
            current != AndroidOwnership.HANDING_OFF_TO_PHONE
        ) {
            if (budsConnected) {
                _ownership.value = AndroidOwnership.PHONE_ACTIVE
            } else if (current == AndroidOwnership.PHONE_ACTIVE) {
                _ownership.value = AndroidOwnership.IDLE
            }
        }
    }

    fun onBleDisconnected() {
        mediaDebounceJob?.cancel()
        mediaDebounceJob = null
        activeHandoffJob?.cancel()
        activeHandoffJob = null
        handoffTimeoutJob?.cancel()
        handoffTimeoutJob = null
        pendingPhoneHandoffReason = null
        handoffGeneration++

        val current = _ownership.value
        if (current == AndroidOwnership.HANDING_OFF_TO_MAC ||
            current == AndroidOwnership.HANDING_OFF_TO_PHONE
        ) {
            _ownership.value = if (budsConnector.isBudsConnected()) {
                AndroidOwnership.PHONE_ACTIVE
            } else {
                AndroidOwnership.IDLE
            }
        }
    }

    fun onBudsConnectionChanged(connected: Boolean) {
        if (connected) {
            if (_ownership.value == AndroidOwnership.HANDING_OFF_TO_PHONE) {
                val reason = pendingPhoneHandoffReason ?: HandoffReason.MEDIA
                pendingPhoneHandoffReason = null
                settleOwnership(AndroidOwnership.PHONE_ACTIVE)
                lastHandoffCompletedAtMs = nowMsProvider()
                bleCoordinator.sendFrame(
                    opcode = HandoffOpcode.STATE_SYNC,
                    reason = HandoffReason.NONE,
                    state = PeerState.BUDS_CONNECTED
                )
                onHandoffBanner("Phone", reason)
            } else if (_ownership.value != AndroidOwnership.HANDING_OFF_TO_MAC &&
                _ownership.value != AndroidOwnership.PHONE_ACTIVE
            ) {
                settleOwnership(AndroidOwnership.PHONE_ACTIVE)
                bleCoordinator.sendFrame(
                    opcode = HandoffOpcode.STATE_SYNC,
                    reason = HandoffReason.NONE,
                    state = PeerState.BUDS_CONNECTED
                )
            }
        } else {
            mediaDebounceJob?.cancel()
            mediaDebounceJob = null
            lastBudsDisconnectedAtMs = nowMsProvider()
            if (_ownership.value == AndroidOwnership.PHONE_ACTIVE) {
                settleOwnership(AndroidOwnership.IDLE)
                bleCoordinator.sendFrame(
                    opcode = HandoffOpcode.STATE_SYNC,
                    reason = HandoffReason.NONE,
                    state = PeerState.IDLE
                )
            }
        }
    }

    fun onCallActiveChanged(inCall: Boolean) {
        isPhoneInCall = inCall
        if (inCall) {
            // Priority invariant: CALL preempts media with 0 ms debounce.
            mediaDebounceJob?.cancel()
            mediaDebounceJob = null
            activeHandoffJob?.cancel()
            val gen = ++handoffGeneration
            pendingPhoneHandoffReason = HandoffReason.CALL
            _ownership.value = AndroidOwnership.HANDING_OFF_TO_PHONE
            scheduleHandoffTimeout()
            bleCoordinator.sendFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.CALL,
                state = PeerState.IN_CALL
            )
            activeHandoffJob = scope.launch {
                val requested = budsConnector.connectBuds()
                if (gen != handoffGeneration) return@launch
                completeOrAwaitPhoneConnect(requested, HandoffReason.CALL)
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
        if (_ownership.value == AndroidOwnership.HANDING_OFF_TO_MAC ||
            _ownership.value == AndroidOwnership.HANDING_OFF_TO_PHONE
        ) {
            return
        }
        if (budsConnector.isBudsConnected()) {
            settleOwnership(AndroidOwnership.PHONE_ACTIVE)
            return
        }
        if (isInCooldown() || isInPostDisconnectGrace()) {
            AppLogger.d(CATEGORY, "Dropping local media bounce during post-handoff/disconnect cooldown")
            return
        }

        mediaDebounceJob?.cancel()
        mediaDebounceJob = scope.launch {
            delay(mediaDebounceMs)
            if (!isLocalMediaPlaying ||
                !_autoSwitchEnabled.value ||
                isPhoneInCall ||
                _ownership.value == AndroidOwnership.HANDING_OFF_TO_MAC ||
                _ownership.value == AndroidOwnership.HANDING_OFF_TO_PHONE ||
                isInCooldown() ||
                isInPostDisconnectGrace() ||
                budsConnector.isBudsConnected()
            ) {
                return@launch
            }
            pendingPhoneHandoffReason = HandoffReason.MEDIA
            _ownership.value = AndroidOwnership.HANDING_OFF_TO_PHONE
            scheduleHandoffTimeout()
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
                activeHandoffJob?.cancel()
                pendingPhoneHandoffReason = null
                val gen = ++handoffGeneration
                if (isLocalMediaPlaying) {
                    pauseLocalMedia()
                }
                _ownership.value = AndroidOwnership.HANDING_OFF_TO_MAC
                scheduleHandoffTimeout()
                activeHandoffJob = scope.launch {
                    budsConnector.disconnectBuds()
                    if (gen != handoffGeneration) return@launch
                    bleCoordinator.sendFrame(
                        opcode = HandoffOpcode.RELEASED,
                        reason = frame.reason,
                        state = PeerState.IDLE
                    )
                }
            }

            HandoffOpcode.RELEASED -> {
                mediaDebounceJob?.cancel()
                mediaDebounceJob = null
                activeHandoffJob?.cancel()
                val gen = ++handoffGeneration
                pendingPhoneHandoffReason = frame.reason
                _ownership.value = AndroidOwnership.HANDING_OFF_TO_PHONE
                scheduleHandoffTimeout()
                activeHandoffJob = scope.launch {
                    val requested = budsConnector.connectBuds()
                    if (gen != handoffGeneration) return@launch
                    completeOrAwaitPhoneConnect(requested, frame.reason)
                }
            }

            HandoffOpcode.STATE_SYNC -> {
                if (frame.state == PeerState.BUDS_CONNECTED) {
                    activeHandoffJob?.cancel()
                    activeHandoffJob = null
                    pendingPhoneHandoffReason = null
                    handoffGeneration++
                    val previousOwnership = _ownership.value
                    settleOwnership(AndroidOwnership.MAC_ACTIVE)
                    val isActiveTransition = previousOwnership == AndroidOwnership.HANDING_OFF_TO_MAC ||
                        (previousOwnership != AndroidOwnership.MAC_ACTIVE && frame.reason != HandoffReason.NONE)
                    if (isActiveTransition) {
                        lastHandoffCompletedAtMs = nowMsProvider()
                        val bannerReason = if (frame.reason != HandoffReason.NONE) {
                            frame.reason
                        } else {
                            HandoffReason.MEDIA
                        }
                        onHandoffBanner("Mac", bannerReason)
                    }
                } else if (frame.state == PeerState.IDLE &&
                    (_ownership.value == AndroidOwnership.HANDING_OFF_TO_MAC ||
                        _ownership.value == AndroidOwnership.MAC_ACTIVE)
                ) {
                    settleOwnership(
                        if (budsConnector.isBudsConnected()) {
                            AndroidOwnership.PHONE_ACTIVE
                        } else {
                            AndroidOwnership.IDLE
                        }
                    )
                }
            }

            HandoffOpcode.HEARTBEAT_ACK -> Unit
        }
    }

    private fun completeOrAwaitPhoneConnect(requested: Boolean, reason: HandoffReason) {
        if (_ownership.value != AndroidOwnership.HANDING_OFF_TO_PHONE) return
        if (budsConnector.isBudsConnected()) {
            pendingPhoneHandoffReason = null
            settleOwnership(AndroidOwnership.PHONE_ACTIVE)
            lastHandoffCompletedAtMs = nowMsProvider()
            bleCoordinator.sendFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.BUDS_CONNECTED
            )
            onHandoffBanner("Phone", reason)
        } else if (!requested) {
            pendingPhoneHandoffReason = null
            settleOwnership(AndroidOwnership.IDLE)
            bleCoordinator.sendFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.IDLE
            )
        }
    }

    private fun settleOwnership(target: AndroidOwnership) {
        handoffTimeoutJob?.cancel()
        handoffTimeoutJob = null
        _ownership.value = target
    }

    private fun scheduleHandoffTimeout() {
        handoffTimeoutJob?.cancel()
        handoffTimeoutJob = scope.launch {
            delay(handoffTimeoutMs)
            val current = _ownership.value
            if (current == AndroidOwnership.HANDING_OFF_TO_MAC ||
                current == AndroidOwnership.HANDING_OFF_TO_PHONE
            ) {
                activeHandoffJob?.cancel()
                activeHandoffJob = null
                handoffGeneration++
                pendingPhoneHandoffReason = null
                val fallback = if (budsConnector.isBudsConnected()) {
                    AndroidOwnership.PHONE_ACTIVE
                } else {
                    AndroidOwnership.IDLE
                }
                AppLogger.w(CATEGORY, "Handoff timed out in $current; resetting to $fallback")
                _ownership.value = fallback
                if (current == AndroidOwnership.HANDING_OFF_TO_PHONE && fallback == AndroidOwnership.IDLE) {
                    bleCoordinator.sendFrame(
                        opcode = HandoffOpcode.STATE_SYNC,
                        reason = HandoffReason.NONE,
                        state = PeerState.IDLE
                    )
                }
            }
        }
    }

    private fun remainingCooldownMs(): Long {
        val last = lastHandoffCompletedAtMs ?: return 0L
        val elapsed = nowMsProvider() - last
        return if (elapsed < cooldownMs) (cooldownMs - elapsed) else 0L
    }

    private fun isInCooldown(): Boolean = remainingCooldownMs() > 0L

    private fun isInPostDisconnectGrace(): Boolean {
        val last = lastBudsDisconnectedAtMs ?: return false
        return (nowMsProvider() - last) < cooldownMs
    }
}
