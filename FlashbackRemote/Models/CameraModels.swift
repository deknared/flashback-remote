import Foundation

struct ManufacturerData {
    let companyID: UInt16
    let model: UInt16
    let serialNumber: UInt32
    let variant: UInt16
    let filmTypeID: UInt32
    let mediaRemaining: UInt16
    let batteryLevel: UInt8
    let flags: UInt8
    let firmwareMajor: UInt8
    let firmwareMinor: UInt8

    // Matches HTTP Server header format: "Flashback-ONE35V2/0.9.6"
    var firmwareVersion: String { "0.\(firmwareMajor).\(firmwareMinor)" }
    var batteryPercent: Int { Int(batteryLevel) }

    static func parse(_ data: Data) -> ManufacturerData? {
        guard data.count >= 20 else { return nil }
        // Raw advertisement is 22 bytes. Bytes 18-19 are padding zeros.
        // Firmware minor.patch live at bytes 20-21 (yields "0.9.6" from 09 06).
        return ManufacturerData(
            companyID:       UInt16(data[0]) | UInt16(data[1]) << 8,
            model:           UInt16(data[2]) | UInt16(data[3]) << 8,
            serialNumber:    UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24,
            variant:         UInt16(data[8]) | UInt16(data[9]) << 8,
            filmTypeID:      UInt32(data[10]) | UInt32(data[11]) << 8 | UInt32(data[12]) << 16 | UInt32(data[13]) << 24,
            mediaRemaining:  UInt16(data[14]) | UInt16(data[15]) << 8,
            batteryLevel:    data[16],
            flags:           data[17],
            firmwareMajor:   data.count >= 22 ? data[20] : 0,
            firmwareMinor:   data.count >= 22 ? data[21] : 0
        )
    }
}

struct DiscoveredCamera: Identifiable {
    let id: UUID
    let name: String
    var rssi: Int
    var manufacturerData: ManufacturerData?
    var isWound: Bool = false
}

enum WiFiStatus {
    case off
    case starting
    case up(ip: String)
    case failed(String)
}
