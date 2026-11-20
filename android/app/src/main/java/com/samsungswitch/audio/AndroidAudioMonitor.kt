package com.samsungswitch.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyEvent
import com.samsungswitch.ble.AppLogger

interface AudioMonitor {
    fun start(
        onMediaPlayingChanged: (Boolean) -> Unit,
        onCallActiveChanged: (Boolean) -> Unit,
        onBudsConnectionChanged: (Boolean) -> Unit = {}
    )
    fun stop()
    fun pauseLocalMedia()
}

class AndroidAudioMonitor(
    context: Context,
    private val isBudsConnectedProvider: () -> Boolean = { false }
) : AudioMonitor {

    companion object {
        private const val CATEGORY = "AndroidAudioMonitor"
        private const val AUDIO_FOCUS_HOLD_MS = 600L
    }

    private val audioManager: AudioManager = context.getSystemService(AudioManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var registered = false
    private var lastMediaPlaying = false
    private var lastCallActive = false
    private var lastBudsConnected = false
    private var mediaCallback: ((Boolean) -> Unit)? = null
    private var callCallback: ((Boolean) -> Unit)? = null
    private var budsConnectionCallback: ((Boolean) -> Unit)? = null
    private var activeFocusRequest: AudioFocusRequest? = null
    private var abandonFocusRunnable: Runnable? = null

    private val playbackCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: List<AudioPlaybackConfiguration>) {
            evaluatePlaybackConfigs(configs)
        }
    }

    private val modeChangedListener = AudioManager.OnModeChangedListener { mode ->
        evaluateCallMode(mode)
    }

    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            evaluateBudsConnection()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            evaluateBudsConnection()
        }
    }

    override fun start(
        onMediaPlayingChanged: (Boolean) -> Unit,
        onCallActiveChanged: (Boolean) -> Unit,
        onBudsConnectionChanged: (Boolean) -> Unit
    ) {
        if (registered) return
        mediaCallback = onMediaPlayingChanged
        callCallback = onCallActiveChanged
        budsConnectionCallback = onBudsConnectionChanged

        lastBudsConnected = isBudsConnectedProvider()
        audioManager.registerAudioPlaybackCallback(playbackCallback, mainHandler)
        audioManager.addOnModeChangedListener(
            { command -> mainHandler.post(command) },
            modeChangedListener
        )
        audioManager.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
        registered = true

        lastMediaPlaying = hasActiveMedia(audioManager.activePlaybackConfigurations)
        val inCall = isCallMode(audioManager.mode)
        lastCallActive = inCall
        AppLogger.i(
            CATEGORY,
            "Registered audio listeners (initialMedia=$lastMediaPlaying, inCall=$inCall, buds=$lastBudsConnected)"
        )
        if (inCall) {
            callCallback?.invoke(true)
        }
    }

    override fun stop() {
        if (!registered) return
        registered = false
        audioManager.unregisterAudioPlaybackCallback(playbackCallback)
        audioManager.removeOnModeChangedListener(modeChangedListener)
        audioManager.unregisterAudioDeviceCallback(audioDeviceCallback)
        abandonPendingAudioFocus()
        mediaCallback = null
        callCallback = null
        budsConnectionCallback = null
        lastMediaPlaying = false
        lastCallActive = false
        lastBudsConnected = false
        AppLogger.i(CATEGORY, "Unregistered audio listeners (BLE disconnected)")
    }

    override fun pauseLocalMedia() {
        val now = SystemClock.uptimeMillis()
        val down = KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PAUSE, 0)
        val up = KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PAUSE, 0)
        audioManager.dispatchMediaKeyEvent(down)
        audioManager.dispatchMediaKeyEvent(up)

        abandonPendingAudioFocus()
        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .build()
        activeFocusRequest = focusRequest
        audioManager.requestAudioFocus(focusRequest)

        val abandonRunnable = Runnable {
            if (activeFocusRequest === focusRequest) {
                audioManager.abandonAudioFocusRequest(focusRequest)
                activeFocusRequest = null
            }
            abandonFocusRunnable = null
        }
        abandonFocusRunnable = abandonRunnable
        mainHandler.postDelayed(abandonRunnable, AUDIO_FOCUS_HOLD_MS)
        AppLogger.i(CATEGORY, "Dispatched local media pause")
    }

    private fun abandonPendingAudioFocus() {
        abandonFocusRunnable?.let { mainHandler.removeCallbacks(it) }
        abandonFocusRunnable = null
        activeFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        activeFocusRequest = null
    }

    private fun evaluateBudsConnection() {
        if (!registered) return
        val connected = isBudsConnectedProvider()
        if (connected != lastBudsConnected) {
            lastBudsConnected = connected
            AppLogger.i(CATEGORY, "Buds audio output connected=$connected")
            budsConnectionCallback?.invoke(connected)
        }
    }

    private fun evaluatePlaybackConfigs(configs: List<AudioPlaybackConfiguration>) {
        val playingMedia = hasActiveMedia(configs)
        if (playingMedia != lastMediaPlaying) {
            lastMediaPlaying = playingMedia
            AppLogger.d(CATEGORY, "Media playback active=$playingMedia")
            mediaCallback?.invoke(playingMedia)
        }
    }

    private fun evaluateCallMode(mode: Int) {
        val inCall = isCallMode(mode)
        if (inCall != lastCallActive) {
            lastCallActive = inCall
            AppLogger.i(CATEGORY, "Call mode active=$inCall (mode=$mode)")
            callCallback?.invoke(inCall)
        }
    }

    private fun hasActiveMedia(configs: List<AudioPlaybackConfiguration>): Boolean {
        return configs.any { config ->
            val usage = config.audioAttributes.usage
            usage == AudioAttributes.USAGE_MEDIA || usage == AudioAttributes.USAGE_GAME
        }
    }

    private fun isCallMode(mode: Int): Boolean {
        return mode == AudioManager.MODE_RINGTONE ||
            mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION
    }
}
