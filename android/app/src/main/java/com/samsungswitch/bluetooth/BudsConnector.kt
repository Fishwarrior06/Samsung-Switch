package com.samsungswitch.bluetooth

interface BudsConnector {
    val backendName: String
    fun isReady(): Boolean
    fun isBudsConnected(): Boolean
    fun getBudsDisplayName(): String?
    suspend fun connectBuds(): Boolean
    suspend fun disconnectBuds(): Boolean
}
