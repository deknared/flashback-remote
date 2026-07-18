import SwiftUI

struct ContentView: View {
    @EnvironmentObject var filesViewModel: FilesViewModel
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var updateChecker = UpdateChecker()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .camera
    @State private var hideTabBar = false

    enum Tab {
        case camera, files, library, editor, settings
    }

    private let tabs: [GlassTabBar.Item] = [
        .init(tab: .camera,   title: "Camera",   icon: "camera"),
        .init(tab: .files,    title: "Files",    icon: "folder"),
        .init(tab: .library,  title: "Library",  icon: "photo.on.rectangle"),
        .init(tab: .editor,   title: "Editor",   icon: "wand.and.stars"),
        .init(tab: .settings, title: "Settings", icon: "gearshape")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                CameraTab()
                    .tag(Tab.camera)
                    .toolbar(.hidden, for: .tabBar)
                FilesTab()
                    .tag(Tab.files)
                    .toolbar(.hidden, for: .tabBar)
                LibraryTab(hideTabBar: $hideTabBar)
                    .tag(Tab.library)
                    .toolbar(.hidden, for: .tabBar)
                EditorTab()
                    .tag(Tab.editor)
                    .toolbar(.hidden, for: .tabBar)
                NavigationStack {
                    SettingsView()
                }
                .tag(Tab.settings)
                .toolbar(.hidden, for: .tabBar)
            }

            if !hideTabBar {
                GlassTabBar(selection: $selectedTab, items: tabs)
                    .padding(.bottom, 2)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if let latest = updateChecker.updateAvailable {
                UpdateBanner(version: latest) { updateChecker.dismiss() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: updateChecker.updateAvailable)
        .task { updateChecker.check() }
        // Re-check on every return to foreground — a cold-launch-only check
        // misses updates published while the app sat suspended, and silently
        // fails when launched on the camera's internet-less WiFi.
        .onChange(of: scenePhase) { phase in
            if phase == .active { updateChecker.check() }
        }
        .environmentObject(updateChecker)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onReceive(filesViewModel.$switchToFilesTab) { should in
            if should {
                selectedTab = .files
                filesViewModel.switchToFilesTab = false
            }
        }
    }
}
