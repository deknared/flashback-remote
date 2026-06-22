import SwiftUI

struct ContentView: View {
    @EnvironmentObject var filesViewModel: FilesViewModel
    @State private var selectedTab: Tab = .camera

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
                LibraryTab()
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
            // Reserve room at the bottom of each tab's content for the floating bar
            // so the last row (e.g. "Source on GitHub") isn't covered.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 72)
            }

            GlassTabBar(selection: $selectedTab, items: tabs)
                .padding(.bottom, 2)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .onReceive(filesViewModel.$switchToFilesTab) { should in
            if should {
                selectedTab = .files
                filesViewModel.switchToFilesTab = false
            }
        }
    }
}
