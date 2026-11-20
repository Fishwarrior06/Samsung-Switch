package com.samsungswitch.bluetooth;

import android.bluetooth.BluetoothDevice;

interface IA2dpControlService {
    boolean connectA2dp(in BluetoothDevice device);
    void destroy();
}
