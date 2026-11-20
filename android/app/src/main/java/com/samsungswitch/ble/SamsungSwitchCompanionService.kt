package com.samsungswitch.ble

import android.companion.AssociationInfo
import android.companion.CompanionDeviceService
import android.os.Build

class SamsungSwitchCompanionService : CompanionDeviceService() {

    companion object {
        private const val CATEGORY = "CompanionService"
    }

    override fun onCreate() {
        super.onCreate()
        BleLinkManager.ensureInitialized(applicationContext)
    }

    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val address = associationInfo.deviceMacAddress?.toString()
            if (address != null) {
                AppLogger.i(CATEGORY, "Associated Mac appeared (API 33+)")
                BleLinkManager.saveAssociatedAddress(address)
                BleLinkManager.connect(address, autoConnect = true)
            }
        }
    }

    @Deprecated("Deprecated in API 33")
    @Suppress("DEPRECATION")
    override fun onDeviceAppeared(address: String) {
        AppLogger.i(CATEGORY, "Associated Mac appeared (API 31-32)")
        BleLinkManager.saveAssociatedAddress(address)
        BleLinkManager.connect(address, autoConnect = true)
    }

    override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            AppLogger.i(CATEGORY, "Associated Mac disappeared (API 33+)")
            BleLinkManager.onPeerDisappeared()
        }
    }

    @Deprecated("Deprecated in API 33")
    @Suppress("DEPRECATION")
    override fun onDeviceDisappeared(address: String) {
        AppLogger.i(CATEGORY, "Associated Mac disappeared (API 31-32)")
        BleLinkManager.onPeerDisappeared()
    }
}
