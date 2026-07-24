import SwiftUI
import Combine

@main
struct FlashbackRemoteApp: App {
    @StateObject private var bleController = BLEController()
    @StateObject private var cameraViewModel = CameraViewModel()
    @StateObject private var filesViewModel = FilesViewModel()
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var protocolConfig = ProtocolConfig()

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Wire: when BLE confirms WiFi is up, hand off to FilesViewModel
        // (Publishers are set up in body via onReceive to access @StateObject values)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleController)
                .environmentObject(cameraViewModel)
                .environmentObject(filesViewModel)
                .environmentObject(settingsStore)
                .environmentObject(protocolConfig)
                .onReceive(bleController.$wifiStatus) { status in
                    if case .up = status {
                        #if DEBUG
                        filesViewModel.onWiFiReady(mock: bleController.isMockMode)
                        #else
                        filesViewModel.onWiFiReady()
                        #endif
                    }
                }
                .onReceive(bleController.$discoveredCamera) { camera in
                    if let version = camera?.manufacturerData?.firmwareVersion {
                        settingsStore.recordFirmwareVersion(version)
                    }
                }
                // Keep the controller's UUID overrides in sync with Settings. Without
                // this the whole "UUID Overrides (Advanced)" section was inert — values
                // persisted to UserDefaults but never reached BLEController.
                .onReceive(settingsStore.$overrideServiceUUID.dropFirst()) { _ in syncUUIDOverrides() }
                .onReceive(settingsStore.$overrideFB00.dropFirst()) { _ in syncUUIDOverrides() }
                .onReceive(settingsStore.$overrideFB20.dropFirst()) { _ in syncUUIDOverrides() }
                .onReceive(settingsStore.$overrideFB01.dropFirst()) { _ in syncUUIDOverrides() }
                .onReceive(settingsStore.$overrideFB04.dropFirst()) { _ in syncUUIDOverrides() }
                .onReceive(settingsStore.$overrideFB02.dropFirst()) { _ in syncUUIDOverrides() }
                .onReceive(settingsStore.$overrideFB10.dropFirst()) { _ in syncUUIDOverrides() }
                .onReceive(settingsStore.$overrideFB05.dropFirst()) { _ in syncUUIDOverrides() }
                .onReceive(settingsStore.$overrideFB06.dropFirst()) { _ in syncUUIDOverrides() }
                .task {
                    protocolConfig.loadIfNeeded()
                    syncUUIDOverrides()          // apply persisted overrides at launch
                    Notifier.requestAuthorization()
                }
        }
    }

    private func syncUUIDOverrides() {
        bleController.uuidOverrides = settingsStore.bleUUIDOverrides
    }
}
