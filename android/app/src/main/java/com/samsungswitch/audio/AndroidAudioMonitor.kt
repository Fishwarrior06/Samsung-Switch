package com.samsungswitch.audio

import android.content.Context
import android.media.AudioAttributes
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
        onCallActiveChanged: (Boolean) -> Unit
    )
    fun stop()
    fun pauseLocalMedia()
}

class AndroidAudioMonitor(
    context: Context
) : AudioMonitor {

    companion object {
        private const val CATEGORY = "AndroidAudioMonitor"
    }

    private val audioManager: AudioManager = context.getSystemService(AudioManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var registered = false
    private var lastMediaPlaying = false
    private var lastCallActive = false
    private var mediaCallback: ((Boolean) -> Unit)? = null
    private var callCallback: ((Boolean) -> Unit)? = null

    private val playbackCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: List<AudioPlaybackConfiguration>) {
            evaluatePlaybackConfigs(configs)
        }
    }

    private val modeChangedListener = AudioManager.OnModeChangedListener { mode ->
        evaluateCallMode(mode)
    }

    override fun start(
        onMediaPlayingChanged: (Boolean) -> Unit,
        onCallActiveChanged: (Boolean) -> Unit
    ) {
        if (registered) return
        mediaCallback = onMediaPlayingChanged
        callCallback = onCallActiveChanged

        audioManager.registerAudioPlaybackCallback(playbackCallback, mainHandler)
        audioManager.addOnModeChangedListener(
            { command -> mainHandler.post(command) },
            modeChangedListener
        )
        registered = true

        evaluateCallMode(audioManager.mode)
        evaluatePlaybackConfigs(audioManager.activePlaybackConfigurations)
        AppLogger.i(CATEGORY, "Registered AudioPlaybackCallback & OnModeChangedListener")
    }

    override fun stop() {
        if (!registered) return
        registered = false
        audioManager.unregisterAudioPlaybackCallback(playbackCallback)
        audioManager.removeOnModeChangedListener(modeChangedListener)
        mediaCallback = null
        callCallback = null
        lastMediaPlaying = false
        lastCallActive = false
        AppLogger.i(CATEGORY, "Unregistered audio listeners (BLE disconnected)")
    }

    override fun pauseLocalMedia() {
        val now = SystemClock.uptimeMillis()
        val down = KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PAUSE, 0)
        val up = KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_PAUSE, 0)
        audioManager.dispatchMediaKeyEvent(down)
        audioManager.dispatchMediaKeyEvent(up)

        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .build()
        audioManager.requestAudioFocus(focusRequest)
        audioManager.abandonAudioFocusRequest(focusRequest)
        AppLogger.i(CATEGORY, "Dispatched local media pause")
    }

    private fun evaluatePlaybackConfigs(configs: List<AudioPlaybackConfiguration>) {
        val playingMedia = configs.any { config ->
            val usage = config.audioAttributes.usage
            usage == AudioAttributes.USAGE_MEDIA || usage == AudioAttributes.USAGE_GAME
        }
        if (playingMedia != lastMediaPlaying) {
            lastMediaPlaying = playingMedia
            AppLogger.d(CATEGORY, "Media playback active=$playingMedia")
            mediaCallback?.invoke(playingMedia)
        }
    }

    private fun evaluateCallMode(mode: Int) {
        val inCall = mode == AudioManager.MODE_RINGTONE ||
            mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION
        if (inCall != lastCallActive) {
            lastCallActive = inCall
            AppLogger.i(CATEGORY, "Call mode active=$inCall (mode=$mode)")
            callCallback?.invoke(inCall)
        }
    }
}
