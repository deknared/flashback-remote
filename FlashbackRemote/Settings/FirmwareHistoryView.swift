import SwiftUI

struct FirmwareHistoryView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var protocol_: ProtocolConfig

    var body: some View {
        List {
            if settings.seenFirmwareVersions.isEmpty {
                Text("No firmware versions seen yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.seenFirmwareVersions.sorted(by: { $0.key < $1.key }), id: \.key) { version, date in
                    LabeledContent(version) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(protocol_.status(for: version).color)
                                .frame(width: 8, height: 8)
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

            Section {
                Link("View flashback-protocol.json on GitHub",
                     destination: URL(string: "https://github.com/deknared/flashback-remote/blob/main/flashback-protocol.json")!)
                    .font(.callout)
            }
        }
        .navigationTitle("Firmware History")
        .navigationBarTitleDisplayMode(.inline)
    }
}
