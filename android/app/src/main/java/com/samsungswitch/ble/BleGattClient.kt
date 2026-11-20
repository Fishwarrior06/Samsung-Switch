package com.samsungswitch.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import com.samsungswitch.protocol.HandoffFrame
import com.samsungswitch.protocol.HandoffOpcode
import com.samsungswitch.protocol.HandoffReason
import com.samsungswitch.protocol.PeerState
import com.samsungswitch.protocol.ProtocolConstants
import java.util.Locale

@SuppressLint("MissingPermission")
class BleGattClient(
    private val context: Context,
    private val coordinator: BleLinkCoordinator,
    private val initialPeerStateProvider: () -> PeerState = { PeerState.IDLE }
) : BleClientTransport {

    companion object {
        private const val CATEGORY = "BleGattClient"
        private const val GATT_INSUFFICIENT_AUTHENTICATION = 5
        private const val GATT_INSUFFICIENT_ENCRYPTION = 15
        private const val MAX_OUTBOUND_QUEUE_SIZE = 8
    }

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        val manager = context.getSystemService(BluetoothManager::class.java)
        manager?.adapter
    }

    private val writeLock = Any()
    private val outboundQueue = ArrayDeque<HandoffFrame>()
    private var writeInFlight = false

    private var activeGatt: BluetoothGatt? = null
    private var currentTargetAddress: String? = null
    private var lastConnectedAddress: String? = null
    private var connectionActiveOrPending = false
    private var wasConnected = false
    private var userInitiatedDisconnect = false
    private var txToMacChar: BluetoothGattCharacteristic? = null
    private var txToPhoneChar: BluetoothGattCharacteristic? = null
    private var pendingSubscribeAfterBond = false
    private var pendingWriteAfterBond: HandoffFrame? = null
    private var bondReceiverRegistered = false

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
            val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
            val currentAddress = activeGatt?.device?.address ?: return
            if (device?.address != currentAddress) return

            val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
            when (bondState) {
                BluetoothDevice.BOND_BONDING -> {
                    coordinator.updateLinkState(BleLinkState.Bonding)
                }
                BluetoothDevice.BOND_BONDED -> {
                    AppLogger.i(CATEGORY, "BLE bonding completed")
                    val gatt = activeGatt ?: return
                    if (pendingSubscribeAfterBond) {
                        pendingSubscribeAfterBond = false
                        subscribeToTxToPhone(gatt)
                    }
                    pendingWriteAfterBond?.let { frame ->
                        pendingWriteAfterBond = null
                        sendFrame(frame)
                    }
                }
                BluetoothDevice.BOND_NONE -> {
                    val prevState = intent.getIntExtra(
                        BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE,
                        BluetoothDevice.BOND_NONE
                    )
                    if (prevState == BluetoothDevice.BOND_BONDING) {
                        pendingSubscribeAfterBond = false
                        pendingWriteAfterBond = null
                        coordinator.updateLinkState(BleLinkState.Error("BLE bonding failed or canceled"))
                    }
                }
            }
        }
    }

    override fun connect(address: String, autoConnect: Boolean) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            coordinator.updateLinkState(BleLinkState.Error("Bluetooth is disabled"))
            return
        }

        val normalizedAddress = address.uppercase(Locale.US)
        if (activeGatt != null && currentTargetAddress == normalizedAddress && connectionActiveOrPending) {
            AppLogger.d(CATEGORY, "Ignoring redundant GATT connect for active/pending link")
            return
        }

        val device = try {
            adapter.getRemoteDevice(normalizedAddress)
        } catch (e: IllegalArgumentException) {
            AppLogger.e(CATEGORY, "Invalid remote device reference", e)
            coordinator.updateLinkState(BleLinkState.Error("Invalid Bluetooth device"))
            return
        }

        closeCurrentGatt()
        registerBondReceiverIfNeeded()
        userInitiatedDisconnect = false
        currentTargetAddress = normalizedAddress
        lastConnectedAddress = normalizedAddress
        connectionActiveOrPending = true
        coordinator.updateLinkState(BleLinkState.Connecting)
        AppLogger.i(CATEGORY, "Connecting GATT (autoConnect=$autoConnect)")

        activeGatt = device.connectGatt(
            context,
            autoConnect,
            gattCallback,
            BluetoothDevice.TRANSPORT_LE
        )
    }

    override fun disconnect() {
        userInitiatedDisconnect = true
        lastConnectedAddress = null
        wasConnected = false
        pendingSubscribeAfterBond = false
        pendingWriteAfterBond = null
        closeCurrentGatt()
        unregisterBondReceiverIfNeeded()
        coordinator.updateLinkState(BleLinkState.Disconnected)
        AppLogger.i(CATEGORY, "GATT disconnected by client")
    }

    fun onPeerDisappeared() {
        AppLogger.i(CATEGORY, "Peer disappeared callback; keeping passive autoConnect ready")
    }

    override fun sendFrame(frame: HandoffFrame): Boolean {
        val gatt = activeGatt
        val characteristic = txToMacChar
        if (gatt == null || characteristic == null) {
            AppLogger.w(CATEGORY, "Cannot send frame: GATT not ready")
            return false
        }

        synchronized(writeLock) {
            if (writeInFlight) {
                if (outboundQueue.size >= MAX_OUTBOUND_QUEUE_SIZE) {
                    outboundQueue.removeFirst()
                }
                outboundQueue.addLast(frame)
                AppLogger.d(CATEGORY, "Queued TX_TO_MAC (${outboundQueue.size}): ${frame.summary()}")
                return true
            }
            writeInFlight = true
        }

        val started = writeCharacteristicCompat(gatt, characteristic, frame.encode())
        if (started) {
            AppLogger.d(CATEGORY, "Writing TX_TO_MAC: ${frame.summary()}")
        } else {
            synchronized(writeLock) {
                writeInFlight = false
            }
            AppLogger.w(CATEGORY, "Failed to initiate characteristic write")
        }
        return started
    }

    private fun closeCurrentGatt() {
        txToMacChar = null
        txToPhoneChar = null
        connectionActiveOrPending = false
        wasConnected = false
        currentTargetAddress = null
        synchronized(writeLock) {
            outboundQueue.clear()
            writeInFlight = false
        }
        val gatt = activeGatt
        activeGatt = null
        gatt?.let { client ->
            try {
                client.disconnect()
                client.close()
            } catch (e: SecurityException) {
                AppLogger.e(CATEGORY, "Missing permission while closing GATT", e)
            }
        }
    }

    private fun registerBondReceiverIfNeeded() {
        if (bondReceiverRegistered) return
        val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(bondReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(bondReceiver, filter)
        }
        bondReceiverRegistered = true
    }

    private fun unregisterBondReceiverIfNeeded() {
        if (!bondReceiverRegistered) return
        try {
            context.unregisterReceiver(bondReceiver)
        } catch (e: IllegalArgumentException) {
            AppLogger.d(CATEGORY, "Bond receiver already unregistered")
        }
        bondReceiverRegistered = false
    }

    private fun initiateBondingIfNeeded(device: BluetoothDevice) {
        when (device.bondState) {
            BluetoothDevice.BOND_BONDED -> return
            BluetoothDevice.BOND_BONDING -> coordinator.updateLinkState(BleLinkState.Bonding)
            else -> {
                coordinator.updateLinkState(BleLinkState.Bonding)
                val initiated = device.createBond()
                AppLogger.i(CATEGORY, "Initiated BLE bonding: started=$initiated")
            }
        }
    }

    private fun subscribeToTxToPhone(gatt: BluetoothGatt) {
        val characteristic = txToPhoneChar ?: return
        val cccd = characteristic.getDescriptor(ProtocolConstants.CCCD_UUID)
        if (cccd == null) {
            coordinator.updateLinkState(BleLinkState.Error("Missing CCCD on TX_TO_PHONE"))
            return
        }

        gatt.setCharacteristicNotification(characteristic, true)
        val started = writeDescriptorCompat(gatt, cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        AppLogger.d(CATEGORY, "Subscribing to TX_TO_PHONE notifications: started=$started")
    }

    private fun flushNextQueuedWrite(gatt: BluetoothGatt) {
        val characteristic = txToMacChar
        val nextFrame: HandoffFrame? = synchronized(writeLock) {
            if (characteristic != null && outboundQueue.isNotEmpty()) {
                outboundQueue.removeFirst()
            } else {
                writeInFlight = false
                null
            }
        }
        if (nextFrame != null && characteristic != null) {
            val started = writeCharacteristicCompat(gatt, characteristic, nextFrame.encode())
            if (started) {
                AppLogger.d(CATEGORY, "Flushed queued TX_TO_MAC: ${nextFrame.summary()}")
            } else {
                synchronized(writeLock) {
                    writeInFlight = false
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun writeCharacteristicCompat(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        payload: ByteArray
    ): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = gatt.writeCharacteristic(
                characteristic,
                payload,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            )
            if (status != BluetoothStatusCodes.SUCCESS) {
                AppLogger.w(CATEGORY, "writeCharacteristic returned status=$status")
            }
            status == BluetoothStatusCodes.SUCCESS
        } else {
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            characteristic.value = payload
            gatt.writeCharacteristic(characteristic)
        }
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptorCompat(
        gatt: BluetoothGatt,
        descriptor: BluetoothGattDescriptor,
        value: ByteArray
    ): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
        } else {
            descriptor.value = value
            gatt.writeDescriptor(descriptor)
        }
    }

    private fun isAuthOrEncryptionError(status: Int): Boolean {
        return status == GATT_INSUFFICIENT_AUTHENTICATION || status == GATT_INSUFFICIENT_ENCRYPTION
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (gatt !== activeGatt) return
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                connectionActiveOrPending = true
                wasConnected = true
                AppLogger.i(CATEGORY, "GATT connected, discovering services")
                gatt.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val shouldAutoReconnect = !userInitiatedDisconnect &&
                    wasConnected &&
                    lastConnectedAddress != null &&
                    bluetoothAdapter?.isEnabled == true
                val reconnectAddress = lastConnectedAddress
                txToMacChar = null
                txToPhoneChar = null
                connectionActiveOrPending = false
                wasConnected = false
                synchronized(writeLock) {
                    outboundQueue.clear()
                    writeInFlight = false
                }
                coordinator.updateLinkState(BleLinkState.Disconnected)
                AppLogger.i(CATEGORY, "GATT disconnected (status=$status)")
                if (shouldAutoReconnect && reconnectAddress != null) {
                    AppLogger.i(CATEGORY, "Re-arming passive autoConnect GATT after disconnect (status=$status)")
                    connect(reconnectAddress, autoConnect = true)
                }
            } else if (status != BluetoothGatt.GATT_SUCCESS) {
                connectionActiveOrPending = false
                wasConnected = false
                coordinator.updateLinkState(BleLinkState.Error("GATT status=$status"))
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (gatt !== activeGatt) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                coordinator.updateLinkState(BleLinkState.Error("Service discovery failed ($status)"))
                return
            }

            val priorityRequested = gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER)
            AppLogger.i(CATEGORY, "Requested CONNECTION_PRIORITY_LOW_POWER: $priorityRequested")

            val service = gatt.getService(ProtocolConstants.SERVICE_UUID)
            if (service == null) {
                coordinator.updateLinkState(BleLinkState.Error("Samsung Switch GATT service not found"))
                return
            }

            txToMacChar = service.getCharacteristic(ProtocolConstants.TX_TO_MAC_UUID)
            txToPhoneChar = service.getCharacteristic(ProtocolConstants.TX_TO_PHONE_UUID)

            if (txToMacChar == null || txToPhoneChar == null) {
                coordinator.updateLinkState(BleLinkState.Error("Required GATT characteristics missing"))
                return
            }

            subscribeToTxToPhone(gatt)
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            if (gatt !== activeGatt) return
            if (descriptor.uuid != ProtocolConstants.CCCD_UUID) return

            if (status == BluetoothGatt.GATT_SUCCESS) {
                coordinator.updateLinkState(BleLinkState.ConnectedLowPower)
                AppLogger.i(CATEGORY, "Subscribed to TX_TO_PHONE; sending initial STATE_SYNC")
                coordinator.sendFrame(
                    opcode = HandoffOpcode.STATE_SYNC,
                    reason = HandoffReason.NONE,
                    state = initialPeerStateProvider()
                )
            } else if (isAuthOrEncryptionError(status)) {
                AppLogger.i(CATEGORY, "CCCD write requires BLE bonding (status=$status)")
                pendingSubscribeAfterBond = true
                initiateBondingIfNeeded(gatt.device)
            } else {
                coordinator.updateLinkState(BleLinkState.Error("CCCD write failed ($status)"))
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            if (gatt !== activeGatt) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                AppLogger.d(CATEGORY, "TX_TO_MAC write acknowledged")
                flushNextQueuedWrite(gatt)
            } else if (isAuthOrEncryptionError(status)) {
                AppLogger.i(CATEGORY, "Write rejected for missing encryption; waiting/initiating bonding")
                synchronized(writeLock) {
                    writeInFlight = false
                }
                if (gatt.device.bondState == BluetoothDevice.BOND_NONE) {
                    initiateBondingIfNeeded(gatt.device)
                }
            } else {
                AppLogger.w(CATEGORY, "TX_TO_MAC write failed (status=$status)")
                flushNextQueuedWrite(gatt)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (gatt !== activeGatt) return
            handleIncomingNotification(characteristic, value)
        }

        @Deprecated("Deprecated in API 33")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (gatt !== activeGatt) return
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                val value = characteristic.value ?: return
                handleIncomingNotification(characteristic, value)
            }
        }
    }

    private fun handleIncomingNotification(
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray
    ) {
        if (characteristic.uuid != ProtocolConstants.TX_TO_PHONE_UUID) return
        try {
            val frame = HandoffFrame.decode(value)
            AppLogger.d(CATEGORY, "Received TX_TO_PHONE: ${frame.summary()}")
            coordinator.onFrameReceived(frame)
        } catch (e: IllegalArgumentException) {
            AppLogger.w(CATEGORY, "Ignored malformed TX_TO_PHONE frame (${value.size} bytes)")
        }
    }
}
