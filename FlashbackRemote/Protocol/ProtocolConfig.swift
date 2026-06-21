import Foundation
import Combine

private let configURL = URL(string: "https://raw.githubusercontent.com/deknared/flashback-remote/main/flashback-protocol.json")!
private let cacheKey = "flashback_protocol_cache_v2"
private let cacheAgeKey = "flashback_protocol_cache_date_v2"
private let cacheTTL: TimeInterval = 86400  // 24 hours

struct FlashbackProtocol: Codable {
    let schema: Int
    let firmwareVersions: [String: FirmwareEntry]
}

struct FirmwareEntry: Codable {
    let status: String
    let testedDate: String?
    let notes: String?
}

@MainActor
final class ProtocolConfig: ObservableObject {
    @Published var firmwareStatuses: [String: FirmwareStatus] = [:]
    @Published var isLoaded = false

    func loadIfNeeded() {
        if let cached = cachedConfig(), isCacheFresh() {
            apply(cached)
            return
        }
        Task { await fetch() }
    }

    func status(for firmwareVersion: String) -> FirmwareStatus {
        firmwareStatuses[firmwareVersion] ?? .unknown(version: firmwareVersion)
    }

    // MARK: Private

    private func fetch() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: configURL)
            let protocol_ = try JSONDecoder().decode(FlashbackProtocol.self, from: data)
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheAgeKey)
            apply(protocol_)
        } catch {
            // Fall back to cached data if fetch fails
            if let cached = cachedConfig() { apply(cached) }
        }
    }

    private func apply(_ config: FlashbackProtocol) {
        var map: [String: FirmwareStatus] = [:]
        for (version, entry) in config.firmwareVersions {
            switch entry.status {
            case "confirmed_working": map[version] = .confirmed(version: version)
            case "untested":          map[version] = .untested(version: version)
            case "broken":            map[version] = .broken(version: version)
            default:                  map[version] = .unknown(version: version)
            }
        }
        firmwareStatuses = map
        isLoaded = true
    }

    private func cachedConfig() -> FlashbackProtocol? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(FlashbackProtocol.self, from: data)
    }

    private func isCacheFresh() -> Bool {
        guard let date = UserDefaults.standard.object(forKey: cacheAgeKey) as? Date else { return false }
        return Date().timeIntervalSince(date) < cacheTTL
    }
}
