package com.samsungswitch.bluetooth

interface BudsConnector {
    val backendName: String
    fun isReady(): Boolean
    fun isBudsConnected(): Boolean
    suspend fun connectBuds(): Boolean
}
