import SwiftUI

struct ContentView: View {
    @EnvironmentObject var filesViewModel: FilesViewModel
    @State private var selectedTab: Tab = .camera

    enum Tab {
        case camera, files, editor, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            CameraTab()
                .tabItem {
                    Label("Camera", systemImage: "camera.fill")
                }
                .tag(Tab.camera)

            FilesTab()
                .tabItem {
                    Label("Files", systemImage: "folder.fill")
                }
                .tag(Tab.files)

            EditorTab()
                .tabItem {
                    Label("Editor", systemImage: "wand.and.stars")
                }
                .tag(Tab.editor)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
        .onReceive(filesViewModel.$switchToFilesTab) { should in
            if should {
                selectedTab = .files
                filesViewModel.switchToFilesTab = false
            }
        }
    }
}
