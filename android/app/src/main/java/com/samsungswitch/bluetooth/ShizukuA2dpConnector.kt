package com.samsungswitch.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.IBinder
import com.samsungswitch.ble.AppLogger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import rikka.shizuku.Shizuku
import kotlin.coroutines.resume

@SuppressLint("MissingPermission")
class ShizukuA2dpConnector(
    private val context: Context
) : BudsConnector {

    companion object {
        private const val CATEGORY = "ShizukuA2dpConnector"
        private const val BIND_TIMEOUT_MS = 4_000L
        private const val SERVICE_TAG = "a2dp_control"
    }

    override val backendName: String = "Shizuku A2DP"

    private val bluetoothAdapter: BluetoothAdapter? by lazy {
        context.getSystemService(BluetoothManager::class.java)?.adapter
    }

    private val audioManager: AudioManager? by lazy {
        context.getSystemService(AudioManager::class.java)
    }

    @Volatile
    private var boundService: IA2dpControlService? = null

    override fun isReady(): Boolean {
        return try {
            Shizuku.pingBinder() &&
                Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) {
            false
        }
    }

    override fun isBudsConnected(): Boolean {
        val adapter = bluetoothAdapter ?: return false
        val targetDevice = findTargetBudsDevice(adapter) ?: return false
        val targetAddress = targetDevice.address
        val outputs = audioManager?.getDevices(AudioManager.GET_DEVICES_OUTPUTS).orEmpty()
        val connected = outputs.any { info ->
            val isBtAudio = info.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                info.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                info.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
            if (!isBtAudio) return@any false
            val addrMatch = !targetAddress.isNullOrBlank() &&
                info.address.equals(targetAddress, ignoreCase = true)
            val nameMatch = info.productName?.toString()?.contains("buds", ignoreCase = true) == true
            addrMatch || nameMatch
        }
        AppLogger.d(CATEGORY, "Buds audio output connected=$connected")
        return connected
    }

    override fun getBudsDisplayName(): String? {
        val adapter = bluetoothAdapter ?: return null
        return findTargetBudsDevice(adapter)?.name
    }

    override suspend fun connectBuds(): Boolean = invokeUserServiceAction("connectA2dp") { service, device ->
        service.connectA2dp(device)
    }

    override suspend fun disconnectBuds(): Boolean = invokeUserServiceAction("disconnectA2dp") { service, device ->
        service.disconnectA2dp(device)
    }

    private suspend fun invokeUserServiceAction(
        actionName: String,
        action: (IA2dpControlService, BluetoothDevice) -> Boolean
    ): Boolean = withContext(Dispatchers.IO) {
        if (!isReady()) {
            AppLogger.w(CATEGORY, "Shizuku binder not ready or permission not granted")
            return@withContext false
        }

        val adapter = bluetoothAdapter ?: return@withContext false
        val budsDevice = findTargetBudsDevice(adapter)
        if (budsDevice == null) {
            AppLogger.w(CATEGORY, "No paired Galaxy Buds found in bondedDevices")
            return@withContext false
        }

        val service = getOrBindUserService() ?: run {
            AppLogger.w(CATEGORY, "Failed to bind Shizuku A2dpUserService")
            return@withContext false
        }

        return@withContext try {
            val result = action(service, budsDevice)
            AppLogger.i(CATEGORY, "Shizuku A2dpUserService.$actionName() returned $result")
            result
        } catch (e: Throwable) {
            AppLogger.e(CATEGORY, "Remote call to A2dpUserService.$actionName failed", e)
            boundService = null
            false
        }
    }

    private fun findTargetBudsDevice(adapter: BluetoothAdapter): BluetoothDevice? {
        return try {
            val a2dpSinkPrefix = "0000110b"
            val candidates = adapter.bondedDevices.orEmpty().filter { device ->
                val name = device.name?.lowercase().orEmpty()
                name.contains("buds")
            }
            // Prefer Classic/Dual BR-EDR device with A2DP AudioSink UUID over LE-only companion address.
            val selected = candidates.firstOrNull { device ->
                device.type != BluetoothDevice.DEVICE_TYPE_LE &&
                    device.uuids?.any { it.uuid.toString().startsWith(a2dpSinkPrefix, ignoreCase = true) } == true
            } ?: candidates.firstOrNull { device ->
                device.type == BluetoothDevice.DEVICE_TYPE_DUAL ||
                    device.type == BluetoothDevice.DEVICE_TYPE_CLASSIC
            } ?: candidates.firstOrNull { device ->
                device.type != BluetoothDevice.DEVICE_TYPE_LE
            } ?: candidates.firstOrNull()
            if (selected != null) {
                AppLogger.i(CATEGORY, "Selected Buds device type=${selected.type} name=${selected.name}")
            }
            selected
        } catch (_: SecurityException) {
            AppLogger.w(CATEGORY, "Missing BLUETOOTH_CONNECT to query bonded devices")
            null
        }
    }

    private suspend fun getOrBindUserService(): IA2dpControlService? {
        boundService?.let { existing ->
            if (existing.asBinder().pingBinder()) {
                return existing
            }
            boundService = null
        }

        val args = Shizuku.UserServiceArgs(
            ComponentName(context.packageName, A2dpUserService::class.java.name)
        )
            .daemon(false)
            .processNameSuffix("a2dp")
            .debuggable(false)
            .version(7)
            .tag(SERVICE_TAG)

        return withTimeoutOrNull(BIND_TIMEOUT_MS) {
            suspendCancellableCoroutine { cont ->
                val connection = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                        val aidl = IA2dpControlService.Stub.asInterface(service)
                        boundService = aidl
                        if (cont.isActive) {
                            cont.resume(aidl)
                        }
                    }

                    override fun onServiceDisconnected(name: ComponentName?) {
                        boundService = null
                    }
                }
                Shizuku.bindUserService(args, connection)
            }
        }
    }
}
