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
            Log.d(TAG, "[$category] $message")
        }
    }

    fun i(category: String, message: String) {
        Log.i(TAG, "[$category] $message")
    }

    fun w(category: String, message: String) {
        Log.w(TAG, "[$category] $message")
    }

    fun e(category: String, message: String, throwable: Throwable? = null) {
        if (throwable != null && debugEnabled) {
            Log.e(TAG, "[$category] $message", throwable)
        } else {
            Log.e(TAG, "[$category] $message")
        }
    }
}
