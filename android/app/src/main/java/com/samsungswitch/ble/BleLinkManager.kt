package com.samsungswitch.ble

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import androidx.core.content.edit
import com.samsungswitch.audio.AndroidAudioMonitor
import com.samsungswitch.bluetooth.ShizukuA2dpConnector
import com.samsungswitch.protocol.PeerState
import com.samsungswitch.state.AndroidHandoffCoordinator
import java.util.Locale

object BleLinkManager {
    private const val PREFS_NAME = "samsung_switch_prefs"
    private const val KEY_MAC_ADDRESS = "associated_mac_address"

    @Volatile
    private var initialized = false

    private lateinit var appContext: Context
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var gattClient: BleGattClient
    private lateinit var audioMonitor: AndroidAudioMonitor
    lateinit var budsConnector: ShizukuA2dpConnector
        private set
    lateinit var handoffCoordinator: AndroidHandoffCoordinator
        private set

    val coordinator: BleLinkCoordinator = BleLinkCoordinator { gattClient }

    fun ensureInitialized(context: Context) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            appContext = context.applicationContext
            AppLogger.init(appContext)
            budsConnector = ShizukuA2dpConnector(appContext)
            audioMonitor = AndroidAudioMonitor(appContext) { budsConnector.isBudsConnected() }
            gattClient = BleGattClient(
                context = appContext,
                coordinator = coordinator,
                initialPeerStateProvider = {
                    if (budsConnector.isBudsConnected()) PeerState.BUDS_CONNECTED else PeerState.IDLE
                }
            )
            handoffCoordinator = AndroidHandoffCoordinator(
                bleCoordinator = coordinator,
                budsConnector = budsConnector,
                pauseLocalMedia = { audioMonitor.pauseLocalMedia() }
            )

            coordinator.onRemoteFrameListener = { frame ->
                mainHandler.post {
                    handoffCoordinator.onRemoteFrame(frame)
                }
            }
            coordinator.onLinkStateChangedListener = { state ->
                mainHandler.post {
                    when (state) {
                        is BleLinkState.ConnectedLowPower -> {
                            handoffCoordinator.onBleConnected(budsConnector.isBudsConnected())
                            audioMonitor.start(
                                onMediaPlayingChanged = { playing ->
                                    handoffCoordinator.onLocalMediaPlayingChanged(playing)
                                },
                                onCallActiveChanged = { inCall ->
                                    handoffCoordinator.onCallActiveChanged(inCall)
                                },
                                onBudsConnectionChanged = { connected ->
                                    handoffCoordinator.onBudsConnectionChanged(connected)
                                }
                            )
                        }
                        is BleLinkState.Disconnected,
                        is BleLinkState.Error -> {
                            audioMonitor.stop()
                            handoffCoordinator.onBleDisconnected()
                        }
                        else -> Unit
                    }
                }
            }

            coordinator.setAssociatedMacPresent(getAssociatedAddress() != null)
            initialized = true
        }
    }

    private fun prefs(): SharedPreferences {
        return appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    fun saveAssociatedAddress(address: String) {
        val normalized = address.uppercase(Locale.US)
        prefs().edit { putString(KEY_MAC_ADDRESS, normalized) }
        coordinator.setAssociatedMacPresent(true)
    }

    fun getAssociatedAddress(): String? {
        return prefs().getString(KEY_MAC_ADDRESS, null)?.uppercase(Locale.US)
    }

    fun connect(address: String, autoConnect: Boolean = true) {
        gattClient.connect(address, autoConnect)
    }

    fun connectSavedDevice(autoConnect: Boolean = true): Boolean {
        val saved = getAssociatedAddress() ?: return false
        gattClient.connect(saved, autoConnect)
        return true
    }

    fun onPeerDisappeared() {
        gattClient.onPeerDisappeared()
    }

    fun disconnect() {
        audioMonitor.stop()
        gattClient.disconnect()
    }
}
