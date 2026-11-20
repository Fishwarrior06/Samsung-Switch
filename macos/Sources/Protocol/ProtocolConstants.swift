import Foundation

public enum ProtocolConstants {
    public static let protocolVersion: UInt8 = 0x01
    public static let frameLength: Int = 6

    public static let serviceUUIDString = "E4A10001-7C3B-4B2A-9D1E-5A8F00000001"
    public static let txToMacUUIDString = "E4A10002-7C3B-4B2A-9D1E-5A8F00000001"
    public static let txToPhoneUUIDString = "E4A10003-7C3B-4B2A-9D1E-5A8F00000001"

    // Keep <= 8 ASCII chars so LocalName + 128-bit Service UUID fit in a 31-byte BLE ADV packet.
    public static let localDeviceName = "MacSSw"
}
