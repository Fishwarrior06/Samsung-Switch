package com.samsungswitch.ble

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log

object AppLogger {
    private const val TAG = "SamsungSwitch"

    @Volatile
    private var debugEnabled: Boolean = false

    fun init(context: Context) {
        debugEnabled = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    fun d(category: String, message: String) {
        if (debugEnabled) {
            safeLog { Log.d(TAG, "[$category] $message") }
        }
    }

    fun i(category: String, message: String) {
        safeLog { Log.i(TAG, "[$category] $message") }
    }

    fun w(category: String, message: String) {
        safeLog { Log.w(TAG, "[$category] $message") }
    }

    fun e(category: String, message: String, throwable: Throwable? = null) {
        if (throwable != null && debugEnabled) {
            safeLog { Log.e(TAG, "[$category] $message", throwable) }
        } else {
            safeLog { Log.e(TAG, "[$category] $message") }
        }
    }

    private inline fun safeLog(block: () -> Unit) {
        try {
            block()
        } catch (_: RuntimeException) {
            // JVM unit tests do not mock android.util.Log.
        }
    }
}
