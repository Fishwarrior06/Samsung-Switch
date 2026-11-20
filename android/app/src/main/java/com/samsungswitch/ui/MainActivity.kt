package com.samsungswitch.ui

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.widget.Button
import android.widget.TextView
import com.samsungswitch.R
import com.samsungswitch.ble.AppLogger
import com.samsungswitch.ble.BleLinkManager
import com.samsungswitch.ble.BleLinkState
import com.samsungswitch.protocol.HandoffOpcode
import com.samsungswitch.protocol.HandoffReason
import com.samsungswitch.protocol.PeerState
import com.samsungswitch.protocol.ProtocolConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import rikka.shizuku.Shizuku

class MainActivity : Activity() {

    companion object {
        private const val CATEGORY = "MainActivity"
        private const val REQUEST_BLUETOOTH_CONNECT = 1001
        private const val REQUEST_COMPANION_ASSOCIATE = 1002
        private const val REQUEST_SHIZUKU_PERMISSION = 1003
    }

    private val uiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var observerJob: Job? = null
    private var associationHandledForCurrentAttempt = false

    private lateinit var textStatus: TextView
    private lateinit var textMacStatus: TextView
    private lateinit var textShizukuStatus: TextView
    private lateinit var textOwnership: TextView
    private lateinit var textLastRx: TextView
    private lateinit var textLastTx: TextView

    private val shizukuPermissionListener =
        Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
            if (requestCode == REQUEST_SHIZUKU_PERMISSION) {
                AppLogger.i(CATEGORY, "Shizuku permission result: $grantResult")
                refreshShizukuStatus()
            }
        }

    private val companionDeviceManager: CompanionDeviceManager by lazy {
        getSystemService(CompanionDeviceManager::class.java)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        BleLinkManager.ensureInitialized(applicationContext)
        setContentView(R.layout.activity_main)

        textStatus = findViewById(R.id.textStatus)
        textMacStatus = findViewById(R.id.textMacStatus)
        textShizukuStatus = findViewById(R.id.textShizukuStatus)
        textOwnership = findViewById(R.id.textOwnership)
        textLastRx = findViewById(R.id.textLastRx)
        textLastTx = findViewById(R.id.textLastTx)
        Shizuku.addRequestPermissionResultListener(shizukuPermissionListener)
        refreshShizukuStatus()

        findViewById<Button>(R.id.btnPairMac).setOnClickListener {
            if (ensureBluetoothConnectPermission()) {
                startCompanionAssociation()
            }
        }
        findViewById<Button>(R.id.btnConnect).setOnClickListener {
            if (ensureBluetoothConnectPermission()) {
                if (!BleLinkManager.connectSavedDevice(autoConnect = false)) {
                    BleLinkManager.coordinator.updateLinkState(
                        BleLinkState.Error("No associated Mac yet; tap Pair Mac first")
                    )
                }
            }
        }
        findViewById<Button>(R.id.btnGrantShizuku).setOnClickListener {
            requestShizukuPermission()
        }
        findViewById<Button>(R.id.btnConnectBuds).setOnClickListener {
            uiScope.launch {
                BleLinkManager.budsConnector.connectBuds()
                refreshShizukuStatus()
            }
        }
        findViewById<Button>(R.id.btnSendSync).setOnClickListener {
            BleLinkManager.coordinator.sendFrame(
                opcode = HandoffOpcode.STATE_SYNC,
                reason = HandoffReason.NONE,
                state = PeerState.IDLE
            )
        }
        findViewById<Button>(R.id.btnSendClaim).setOnClickListener {
            BleLinkManager.coordinator.sendFrame(
                opcode = HandoffOpcode.CLAIM,
                reason = HandoffReason.MEDIA,
                state = PeerState.PLAYING
            )
        }
        findViewById<Button>(R.id.btnSendHeartbeat).setOnClickListener {
            BleLinkManager.coordinator.sendFrame(
                opcode = HandoffOpcode.HEARTBEAT_ACK,
                reason = HandoffReason.MANUAL,
                state = PeerState.IDLE
            )
        }
        findViewById<Button>(R.id.btnDisconnect).setOnClickListener {
            BleLinkManager.disconnect()
        }

        startObservingStateFlows()
        if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED) {
            BleLinkManager.connectSavedDevice(autoConnect = false)
        }
    }

    override fun onDestroy() {
        Shizuku.removeRequestPermissionResultListener(shizukuPermissionListener)
        observerJob?.cancel()
        uiScope.cancel()
        super.onDestroy()
    }

    private fun refreshShizukuStatus() {
        textShizukuStatus.text = if (BleLinkManager.budsConnector.isReady()) {
            getString(R.string.status_shizuku_ready)
        } else {
            getString(R.string.status_shizuku_needed)
        }
    }

    private fun requestShizukuPermission() {
        try {
            if (!Shizuku.pingBinder()) {
                textShizukuStatus.text = getString(R.string.status_shizuku_needed)
                return
            }
            if (Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
                refreshShizukuStatus()
                return
            }
            Shizuku.requestPermission(REQUEST_SHIZUKU_PERMISSION)
        } catch (e: Throwable) {
            AppLogger.w(CATEGORY, "Shizuku service unavailable")
            refreshShizukuStatus()
        }
    }

    private fun startObservingStateFlows() {
        val coordinator = BleLinkManager.coordinator
        val handoff = BleLinkManager.handoffCoordinator
        observerJob = uiScope.launch {
            launch {
                coordinator.linkState.collectLatest { state ->
                    textStatus.text = getString(R.string.status_ble_format, state.displayText)
                }
            }
            launch {
                coordinator.associatedMacPresent.collectLatest { present ->
                    textMacStatus.text = if (present) {
                        getString(R.string.mac_status_paired)
                    } else {
                        getString(R.string.mac_status_unpaired)
                    }
                }
            }
            launch {
                handoff.ownership.collectLatest { ownership ->
                    textOwnership.text = getString(R.string.status_ownership_format, ownership.name)
                }
            }
            launch {
                coordinator.lastRxSummary.collectLatest { rx ->
                    textLastRx.text = rx
                }
            }
            launch {
                coordinator.lastTxSummary.collectLatest { tx ->
                    textLastTx.text = tx
                }
            }
        }
    }

    private fun ensureBluetoothConnectPermission(): Boolean {
        val granted = checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) {
            requestPermissions(
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                REQUEST_BLUETOOTH_CONNECT
            )
            return false
        }
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_BLUETOOTH_CONNECT) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) {
                startCompanionAssociation()
            } else {
                BleLinkManager.coordinator.updateLinkState(
                    BleLinkState.Error("BLUETOOTH_CONNECT permission denied")
                )
            }
        }
    }

    private fun startCompanionAssociation() {
        associationHandledForCurrentAttempt = false
        BleLinkManager.coordinator.updateLinkState(BleLinkState.Associating)
        val scanFilter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(ProtocolConstants.SERVICE_UUID))
            .build()
        val bleFilter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(scanFilter)
            .build()
        val request = AssociationRequest.Builder()
            .addDeviceFilter(bleFilter)
            .setSingleDevice(true)
            .build()

        val callback = object : CompanionDeviceManager.Callback() {
            override fun onAssociationPending(intentSender: IntentSender) {
                try {
                    startIntentSenderForResult(
                        intentSender,
                        REQUEST_COMPANION_ASSOCIATE,
                        null,
                        0,
                        0,
                        0
                    )
                } catch (e: IntentSender.SendIntentException) {
                    AppLogger.e(CATEGORY, "Failed to launch CompanionDevice picker", e)
                    BleLinkManager.coordinator.updateLinkState(
                        BleLinkState.Error("Unable to open device picker")
                    )
                }
            }

            override fun onAssociationCreated(associationInfo: AssociationInfo) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val address = associationInfo.deviceMacAddress?.toString()
                    if (address != null) {
                        onMacAssociated(address)
                    }
                }
            }

            override fun onFailure(error: CharSequence?) {
                val message = error?.toString() ?: "Association failed"
                AppLogger.w(CATEGORY, "CompanionDevice association failed: $message")
                BleLinkManager.coordinator.updateLinkState(BleLinkState.Error(message))
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            companionDeviceManager.associate(request, mainExecutor, callback)
        } else {
            @Suppress("DEPRECATION")
            companionDeviceManager.associate(request, callback, Handler(Looper.getMainLooper()))
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_COMPANION_ASSOCIATE) return
        if (resultCode != RESULT_OK || data == null) {
            BleLinkManager.coordinator.updateLinkState(BleLinkState.Disconnected)
            return
        }

        val address = extractAssociatedAddress(data)
        if (address == null) {
            BleLinkManager.coordinator.updateLinkState(
                BleLinkState.Error("No Bluetooth address returned by picker")
            )
            return
        }
        onMacAssociated(address)
    }

    @Suppress("DEPRECATION")
    private fun extractAssociatedAddress(data: Intent): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val info = data.getParcelableExtra(
                CompanionDeviceManager.EXTRA_ASSOCIATION,
                AssociationInfo::class.java
            )
            info?.deviceMacAddress?.toString()?.let { return it }

            data.getParcelableExtra(
                CompanionDeviceManager.EXTRA_DEVICE,
                ScanResult::class.java
            )?.device?.address?.let { return it }

            data.getParcelableExtra(
                CompanionDeviceManager.EXTRA_DEVICE,
                BluetoothDevice::class.java
            )?.address?.let { return it }
        } else {
            val parcelable = data.getParcelableExtra<android.os.Parcelable>(
                CompanionDeviceManager.EXTRA_DEVICE
            )
            when (parcelable) {
                is ScanResult -> return parcelable.device?.address
                is BluetoothDevice -> return parcelable.address
            }
        }
        return null
    }

    @SuppressLint("MissingPermission")
    private fun onMacAssociated(address: String) {
        if (associationHandledForCurrentAttempt) return
        associationHandledForCurrentAttempt = true

        AppLogger.i(CATEGORY, "Mac associated via CompanionDeviceManager")
        BleLinkManager.saveAssociatedAddress(address)
        try {
            companionDeviceManager.startObservingDevicePresence(address)
            AppLogger.i(CATEGORY, "Started hardware-offloaded presence observation")
        } catch (e: SecurityException) {
            AppLogger.w(CATEGORY, "Unable to start device presence observation")
        }
        BleLinkManager.connect(address, autoConnect = false)
    }
}
