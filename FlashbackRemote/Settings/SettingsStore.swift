import SwiftUI

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum SaveLocation: String, CaseIterable {
    case photos = "photos"
    case files = "files"
    case icloud = "icloud"

    var displayName: String {
        switch self {
        case .photos:  return "Photos Library"
        case .files:   return "Files App"
        case .icloud:  return "iCloud Drive"
        }
    }
}

final class SettingsStore: ObservableObject {
    @Published var saveLocation: SaveLocation {
        didSet { UserDefaults.standard.set(saveLocation.rawValue, forKey: "saveLocation") }
    }

    // When enabled: JPEGs are not downloaded and are deleted from the camera.
    @Published var dngOnly: Bool {
        didSet { UserDefaults.standard.set(dngOnly, forKey: "dngOnly") }
    }

    // When enabled: downloaded files are always deleted from the camera, without
    // needing the per-transfer toggle.
    @Published var alwaysDeleteFromCamera: Bool {
        didSet { UserDefaults.standard.set(alwaysDeleteFromCamera, forKey: "alwaysDeleteFromCamera") }
    }

    // Name of a user Shortcut to run from the Files tab (USB import workflow).
    @Published var shortcutName: String {
        didSet { UserDefaults.standard.set(shortcutName, forKey: "shortcutName") }
    }

    // App appearance override (System / Light / Dark).
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }

    // How many files to download from the camera at once. Bounds are enforced by
    // the Stepper (1...6) and clamped again where it's used — never reassign this
    // inside its own didSet (that re-publishes mid view-update and crashes).
    @Published var downloadConcurrency: Int {
        didSet { UserDefaults.standard.set(downloadConcurrency, forKey: "downloadConcurrency") }
    }

    // When enabled: the Editor tab loads the staging build of the web editor.
    @Published var useStagingEditor: Bool {
        didSet { UserDefaults.standard.set(useStagingEditor, forKey: "useStagingEditor") }
    }

    static let editorProductionURL = URL(string: "https://flashback-raw-editor-web.deknared.workers.dev")!
    static let editorStagingURL = URL(string: "https://flashback-raw-editor-web-staging.deknared.workers.dev")!

    var editorURL: URL {
        useStagingEditor ? Self.editorStagingURL : Self.editorProductionURL
    }

    // UUID overrides — nil means "use default"
    @Published var overrideServiceUUID: String = ""
    @Published var overrideFB00: String = ""
    @Published var overrideFB20: String = ""
    @Published var overrideFB01: String = ""
    @Published var overrideFB04: String = ""
    @Published var overrideFB02: String = ""
    @Published var overrideFB10: String = ""

    // Seen firmware versions: [version: dateFirstSeen]
    @Published var seenFirmwareVersions: [String: Date] = [:]

    // Firmware versions that passed the in-app compatibility self-test on this
    // device. Treated as confirmed locally even if the remote protocol json
    // hasn't been updated yet.
    @Published var locallyConfirmedFirmware: [String] = []

    init() {
        let raw = UserDefaults.standard.string(forKey: "saveLocation") ?? SaveLocation.files.rawValue
        saveLocation = SaveLocation(rawValue: raw) ?? .files
        dngOnly = UserDefaults.standard.object(forKey: "dngOnly") as? Bool ?? false
        alwaysDeleteFromCamera = UserDefaults.standard.object(forKey: "alwaysDeleteFromCamera") as? Bool ?? false
        shortcutName = UserDefaults.standard.string(forKey: "shortcutName") ?? ""
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
        downloadConcurrency = (UserDefaults.standard.object(forKey: "downloadConcurrency") as? Int).map { min(max($0, 1), 6) } ?? 1
        useStagingEditor = UserDefaults.standard.object(forKey: "useStagingEditor") as? Bool ?? false

        overrideServiceUUID = UserDefaults.standard.string(forKey: "ov_serviceUUID") ?? ""
        overrideFB00        = UserDefaults.standard.string(forKey: "ov_FB00") ?? ""
        overrideFB20        = UserDefaults.standard.string(forKey: "ov_FB20") ?? ""
        overrideFB01        = UserDefaults.standard.string(forKey: "ov_FB01") ?? ""
        overrideFB04        = UserDefaults.standard.string(forKey: "ov_FB04") ?? ""
        overrideFB02        = UserDefaults.standard.string(forKey: "ov_FB02") ?? ""
        overrideFB10        = UserDefaults.standard.string(forKey: "ov_FB10") ?? ""

        if let raw = UserDefaults.standard.dictionary(forKey: "seenFirmware") as? [String: Date] {
            seenFirmwareVersions = raw
        }
        locallyConfirmedFirmware = UserDefaults.standard.stringArray(forKey: "locallyConfirmedFirmware") ?? []
    }

    func markFirmwareLocallyConfirmed(_ version: String) {
        guard !locallyConfirmedFirmware.contains(version) else { return }
        locallyConfirmedFirmware.append(version)
        UserDefaults.standard.set(locallyConfirmedFirmware, forKey: "locallyConfirmedFirmware")
    }

    func recordFirmwareVersion(_ version: String) {
        // Ignore placeholder/mock readings like "0.0" that aren't real firmware.
        guard version != "0.0", !version.isEmpty else { return }
        guard seenFirmwareVersions[version] == nil else { return }
        seenFirmwareVersions[version] = Date()
        UserDefaults.standard.set(seenFirmwareVersions, forKey: "seenFirmware")
    }

    func removeFirmwareVersion(_ version: String) {
        seenFirmwareVersions.removeValue(forKey: version)
        UserDefaults.standard.set(seenFirmwareVersions, forKey: "seenFirmware")
    }

    func resetUUIDOverrides() {
        overrideServiceUUID = ""; overrideFB00 = ""; overrideFB20 = ""
        overrideFB01 = ""; overrideFB04 = ""; overrideFB02 = ""; overrideFB10 = ""
        ["ov_serviceUUID","ov_FB00","ov_FB20","ov_FB01","ov_FB04","ov_FB02","ov_FB10"]
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func saveUUIDOverrides() {
        UserDefaults.standard.set(overrideServiceUUID, forKey: "ov_serviceUUID")
        UserDefaults.standard.set(overrideFB00, forKey: "ov_FB00")
        UserDefaults.standard.set(overrideFB20, forKey: "ov_FB20")
        UserDefaults.standard.set(overrideFB01, forKey: "ov_FB01")
        UserDefaults.standard.set(overrideFB04, forKey: "ov_FB04")
        UserDefaults.standard.set(overrideFB02, forKey: "ov_FB02")
        UserDefaults.standard.set(overrideFB10, forKey: "ov_FB10")
    }

    var bleUUIDOverrides: BLEUUIDOverrides {
        BLEUUIDOverrides(
            serviceUUID:   overrideServiceUUID.isEmpty ? nil : overrideServiceUUID,
            auth:          overrideFB00.isEmpty ? nil : overrideFB00,
            rollPrimary:   overrideFB20.isEmpty ? nil : overrideFB20,
            rollFallbacks: nil,
            wifiMode:      overrideFB01.isEmpty ? nil : overrideFB01,
            wifiTrigger:   overrideFB04.isEmpty ? nil : overrideFB04,
            wifiStatus:    overrideFB02.isEmpty ? nil : overrideFB02,
            isWound:       overrideFB10.isEmpty ? nil : overrideFB10
        )
    }
}
