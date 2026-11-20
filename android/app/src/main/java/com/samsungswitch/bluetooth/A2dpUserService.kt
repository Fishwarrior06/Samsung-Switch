package com.samsungswitch.bluetooth

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.AttributionSource
import android.content.Context
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import android.util.Log
import androidx.annotation.Keep
import rikka.shizuku.SystemServiceHelper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.system.exitProcess

@Keep
@SuppressLint("MissingPermission")
class A2dpUserService(
    private val context: Context
) : IA2dpControlService.Stub() {

    companion object {
        private const val TAG = "SamsungSwitchA2dpSvc"
        private const val DESCRIPTOR_BM_CALLBACK = "android.bluetooth.IBluetoothManagerCallback"
    }

    override fun connectA2dp(device: BluetoothDevice): Boolean {
        val bmBinder = SystemServiceHelper.getSystemService("bluetooth_manager")
        if (bmBinder == null) {
            Log.w(TAG, "SystemServiceHelper.getSystemService(bluetooth_manager) returned null")
            return false
        }

        return try {
            val bmStub = Class.forName("android.bluetooth.IBluetoothManager\$Stub")
            val bm = bmStub.getMethod("asInterface", IBinder::class.java).invoke(null, bmBinder)
                ?: return false

            val bluetoothAdapter = obtainIBluetooth(bm) ?: return false
            invokeConnectProfiles(bluetoothAdapter, device)
        } catch (e: Throwable) {
            Log.e(TAG, "connectA2dp via IBluetoothManager failed", e)
            false
        }
    }

    private fun obtainIBluetooth(bm: Any): Any? {
        val methods = bm.javaClass.methods
        val registerMethod = methods.firstOrNull {
            it.name == "registerAdapter" && it.parameterTypes.size == 1
        }
        if (registerMethod != null) {
            val callbackInterface = registerMethod.parameterTypes[0]
            val callbackStubClass = Class.forName("android.bluetooth.IBluetoothManagerCallback\$Stub")
            val asInterface = callbackStubClass.getMethod("asInterface", IBinder::class.java)

            val latch = CountDownLatch(1)
            val bluetoothRef = AtomicReference<Any?>(null)

            val rawBinder = object : Binder() {
                override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                    if (code == FIRST_CALL_TRANSACTION) {
                        // onBluetoothServiceUp(IBluetooth bluetoothService)
                        data.enforceInterface(DESCRIPTOR_BM_CALLBACK)
                        val btBinder = data.readStrongBinder()
                        if (btBinder != null) {
                            val btStub = Class.forName("android.bluetooth.IBluetooth\$Stub")
                            val bt = btStub.getMethod("asInterface", IBinder::class.java)
                                .invoke(null, btBinder)
                            bluetoothRef.set(bt)
                        }
                        latch.countDown()
                        return true
                    }
                    return super.onTransact(code, data, reply, flags)
                }
            }
            rawBinder.attachInterface(null, DESCRIPTOR_BM_CALLBACK)
            val callbackProxy = asInterface.invoke(null, rawBinder)

            val ret = registerMethod.invoke(bm, callbackProxy)
            Log.i(TAG, "registerAdapter returned: ${ret?.javaClass?.name} ($ret)")
            if (ret is IBinder) {
                val btStub = Class.forName("android.bluetooth.IBluetooth\$Stub")
                return btStub.getMethod("asInterface", IBinder::class.java).invoke(null, ret)
            }
            if (ret != null && ret !is Boolean && callbackInterface != ret.javaClass) {
                if (ret.javaClass.name.contains("IBluetooth")) {
                    return ret
                }
            }
            latch.await(2, TimeUnit.SECONDS)
            bluetoothRef.get()?.let { return it }
        }

        Log.w(TAG, "IBluetoothManager methods: ${methods.map { it.name }.distinct()}")
        return null
    }

    private fun invokeConnectProfiles(bluetooth: Any, device: BluetoothDevice): Boolean {
        val attributionSource = AttributionSource.Builder(Process.myUid())
            .setPackageName("com.android.shell")
            .build()

        val connectMethods = bluetooth.javaClass.methods.filter {
            it.name == "connectAllEnabledProfiles"
        }
        Log.i(
            TAG,
            "IBluetooth(${bluetooth.javaClass.name}).connectAllEnabledProfiles: ${
                connectMethods.map { m -> m.parameterTypes.map { it.simpleName } }
            }"
        )

        for (method in connectMethods) {
            val params = method.parameterTypes
            if (params.size == 2 && params[0] == BluetoothDevice::class.java) {
                val res = method.invoke(bluetooth, device, attributionSource)
                Log.i(TAG, "Invoked connectAllEnabledProfiles(device, attr) -> $res")
                return when (res) {
                    is Int -> res == 0
                    is Boolean -> res
                    else -> true
                }
            }
            if (params.size == 3 && params[0] == BluetoothDevice::class.java) {
                val receiver = params[2].getDeclaredConstructor().newInstance()
                method.invoke(bluetooth, device, attributionSource, receiver)
                Log.i(TAG, "Invoked connectAllEnabledProfiles(device, attr, receiver)")
                return true
            }
        }

        Log.w(
            TAG,
            "IBluetooth connect methods: ${
                bluetooth.javaClass.methods.filter { it.name.contains("connect", ignoreCase = true) }
                    .map { it.name }
            }"
        )
        return false
    }

    override fun destroy() {
        exitProcess(0)
    }
}
