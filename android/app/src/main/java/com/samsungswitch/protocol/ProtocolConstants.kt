package com.samsungswitch.protocol

import java.util.UUID

object ProtocolConstants {
    const val PROTOCOL_VERSION: Byte = 0x01
    const val FRAME_LENGTH: Int = 6

    val SERVICE_UUID: UUID = UUID.fromString("E4A10001-7C3B-4B2A-9D1E-5A8F00000001")
    val TX_TO_MAC_UUID: UUID = UUID.fromString("E4A10002-7C3B-4B2A-9D1E-5A8F00000001")
    val TX_TO_PHONE_UUID: UUID = UUID.fromString("E4A10003-7C3B-4B2A-9D1E-5A8F00000001")
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
}
