import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var protocol_: ProtocolConfig
    @State private var showResetConfirm = false
    @State private var showUUIDSection = false

    var body: some View {
        Form {
            saveLocationSection
            shortcutSection
            editorSection
            firmwareLogSection
            diagnosticsSection
            uuidOverridesSection
            aboutSection

            // Clears the floating tab bar so the last row isn't hidden behind it.
            Section { Color.clear.frame(height: 70) }
                .listRowBackground(Color.clear)
        }
        .navigationTitle("Settings")
    }

    private var editorSection: some View {
        Section {
            Toggle("Use beta editor", isOn: $settings.useStagingEditor)
        } header: {
            Text("Editor")
        } footer: {
            Text(settings.useStagingEditor
                 ? "Editor tab loads the beta build."
                 : "Editor tab loads the production build. Turn on to try the beta editor.")
        }
    }

    // MARK: Sections

    private var saveLocationSection: some View {
        Section {
            Picker("Destination", selection: $settings.saveLocation) {
                ForEach(SaveLocation.allCases, id: \.self) { loc in
                    Text(loc.displayName).tag(loc)
                }
            }
            Toggle("DNGs only (skip + delete JPEGs)", isOn: $settings.dngOnly)
            Toggle("Always delete from camera", isOn: $settings.alwaysDeleteFromCamera)
            Stepper(value: $settings.downloadConcurrency, in: 1...6) {
                LabeledContent("Parallel downloads", value: "\(settings.downloadConcurrency)")
            }
        } header: {
            Text("Downloads")
        } footer: {
            if settings.alwaysDeleteFromCamera {
                Text("Files are deleted from the camera after every download — no need to toggle it each time.")
            } else if settings.dngOnly {
                Text("JPEGs will be deleted from the camera without being saved. Files save to On My iPhone → Flashback Remote.")
            } else {
                Text("Both DNG and JPEG files will be downloaded. Files App: On My iPhone → Flashback Remote.")
            }
        }
    }

    private var shortcutSection: some View {
        Section {
            TextField("Shortcut name", text: $settings.shortcutName)
                .autocorrectionDisabled()
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Enter the exact name of a Shortcut to show a \"Run Shortcut\" button on the Files tab — handy for a USB import shortcut. Leave blank to hide it.")
        }
    }

    @ViewBuilder
    private var firmwareLogSection: some View {
        let entries = settings.seenFirmwareVersions.sorted(by: { $0.key < $1.key })
        Section("Firmware History") {
            if entries.isEmpty {
                Text("No firmware versions seen yet")
                    .foregroundStyle(.secondary)
            } else if entries.count > 5 {
                // Too many to list inline — push to a dedicated page.
                NavigationLink {
                    FirmwareHistoryView()
                } label: {
                    LabeledContent("All versions", value: "\(entries.count)")
                }
            } else {
                ForEach(entries, id: \.key) { version, date in
                    LabeledContent(version) {
                        HStack(spacing: 6) {
                            firmwareDot(for: version)
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            settings.removeFirmwareVersion(version)
                        }
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.appVersion)
            NavigationLink {
                WhatsNewView()
            } label: {
                Text("What's New")
            }
            NavigationLink {
                CreditsView()
            } label: {
                Text("Credits")
            }
            Link("Source on GitHub",
                 destination: URL(string: "https://github.com/deknared/flashback-remote")!)
        }
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsView()
            } label: {
                Label("BLE Diagnostics", systemImage: "stethoscope")
            }
        } footer: {
            Text("Inspect raw characteristic values — use this to find the camera's WiFi name and password.")
        }
    }

    private var uuidOverridesSection: some View {
        Section {
            DisclosureGroup("UUID Overrides (Advanced)", isExpanded: $showUUIDSection) {
                Text("Only change these if a firmware update broke compatibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)

                uuidField("Service UUID", text: $settings.overrideServiceUUID, placeholder: "46246F52-C9F2-49A6-821B-D68F02298C97")
                uuidField("Auth (FB00)", text: $settings.overrideFB00, placeholder: "FB00")
                uuidField("Roll primary (FB20)", text: $settings.overrideFB20, placeholder: "FB20")
                uuidField("WiFi mode (FB01)", text: $settings.overrideFB01, placeholder: "FB01")
                uuidField("WiFi trigger (FB04)", text: $settings.overrideFB04, placeholder: "FB04")
                uuidField("WiFi status (FB02)", text: $settings.overrideFB02, placeholder: "FB02")
                uuidField("Is wound (FB10)", text: $settings.overrideFB10, placeholder: "FB10")

                HStack {
                    Button("Save") { settings.saveUUIDOverrides() }
                        .buttonStyle(.borderedProminent)
                    Button("Reset to Defaults", role: .destructive) {
                        showResetConfirm = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
        }
        .confirmationDialog("Reset all UUID overrides to factory defaults?",
                             isPresented: $showResetConfirm,
                             titleVisibility: .visible) {
            Button("Reset", role: .destructive) { settings.resetUUIDOverrides() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Helpers

    private func uuidField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        LabeledContent(label) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
        }
    }

    @ViewBuilder
    private func firmwareDot(for version: String) -> some View {
        let status = protocol_.status(for: version)
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
    }
}

// MARK: - What's New

struct WhatsNewView: View {
    private struct Release: Identifiable {
        let id = UUID()
        let version: String
        let notes: [String]
    }

    private let releases: [Release] = [
        Release(version: "1.1.4", notes: [
            "Library: multi-photo Share now works",
            "Swipe left/right between photos in the viewer",
            "Smoother filmstrip (only the open photo expands) and pinch-zoom",
            "File name no longer hidden behind the filmstrip",
            "This What's New page"
        ]),
        Release(version: "1.1.3", notes: [
            "Photos-style Library: full-screen viewer with a scrollable filmstrip",
            "Long-press to select; Share / Delete / Select All in a glass action bar",
            "Removed the Select button; large title to match the other tabs"
        ]),
        Release(version: "1.1.2", notes: [
            "Library now decodes ONE35 DNGs correctly (native Bayer decoder) — no more colour banding",
            "Thumbnails are cached so the Library reopens instantly",
            "Editor: effects/export no longer hidden behind the tab bar"
        ]),
        Release(version: "1.1.1", notes: [
            "Editor returned to full-screen (no top bar)",
            "Library selection + share groundwork",
            "Download concurrency made a setting"
        ]),
        Release(version: "1.1.0", notes: [
            "Settings moved into its own tab; new floating glass tab bar",
            "New Library tab to preview and prune photos on-device",
            "Pull-to-refresh in the Editor; parallel downloads",
            "New app icon"
        ])
    ]

    var body: some View {
        List {
            ForEach(releases) { release in
                Section("Version \(release.version)") {
                    ForEach(release.notes, id: \.self) { note in
                        Label(note, systemImage: "circle.fill")
                            .labelStyle(BulletLabelStyle())
                    }
                }
            }
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.tint)
            configuration.title
                .font(.callout)
        }
    }
}

