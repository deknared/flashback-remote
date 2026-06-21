import SwiftUI

struct CreditsView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Flashback Remote")
                        .font(.headline)
                    Text("Version \(SettingsView.appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("An unofficial companion app for the Flashback ONE35 V2 film camera. Not affiliated with or endorsed by Flashback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }

            Section("Created By") {
                Text("deknared")
                    .font(.callout)
            }

            Section("Built with") {
                creditRow("Embedded RAW editor", detail: "Flashback web editor (PWA)")
                creditRow("BLE protocol", detail: "Reverse-engineered from the official app and BLE traffic")
                creditRow("Distribution", detail: "SideStore")
            }

            Section {
                Link("Report an issue / contribute",
                     destination: URL(string: "https://github.com/deknared/flashback-remote/issues")!)
            }
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func creditRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
