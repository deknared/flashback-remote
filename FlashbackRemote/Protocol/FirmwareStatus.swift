import SwiftUI

enum FirmwareStatus: Equatable {
    case confirmed(version: String)
    case untested(version: String)
    case broken(version: String)
    case unknown(version: String)

    var version: String {
        switch self {
        case .confirmed(let v), .untested(let v), .broken(let v), .unknown(let v): return v
        }
    }

    var color: Color {
        switch self {
        case .confirmed: return .green
        case .untested:  return .yellow
        case .broken:    return .red
        case .unknown:   return .gray
        }
    }

    var label: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .untested:  return "Untested"
        case .broken:    return "Broken"
        case .unknown:   return "Unknown"
        }
    }
}
