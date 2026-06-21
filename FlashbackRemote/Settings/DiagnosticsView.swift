import SwiftUI
import CoreBluetooth

struct DiagnosticsView: View {
    @EnvironmentObject var ble: BLEController

    var body: some View {
        List {
            actionsSection
            characteristicsSection
            logSection
        }
        .navigationTitle("BLE Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var actionsSection: some View {
        Section {
            Button("Read All Characteristics") { ble.diagReadAll() }
            Button("Auth + Read All") { ble.diagAuthThenReadAll() }
            Button("Trigger WiFi + Read All") { ble.diagTriggerWiFiThenReadAll() }
            Button("Clear", role: .destructive) { ble.diagClear() }
        } header: {
            Text("Actions")
        } footer: {
            Text("To find the camera's WiFi name/password: connect on the Camera tab, then tap \"Trigger WiFi + Read All\". Look for any characteristic whose ASCII value looks like a network name or password.")
        }
    }

    private var characteristicsSection: some View {
        Section("Characteristics (\(ble.discoveredCharacteristicInfo.count))") {
            if ble.discoveredCharacteristicInfo.isEmpty {
                Text("Not connected — connect on the Camera tab first")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.discoveredCharacteristicInfo, id: \.uuid) { info in
                    characteristicRow(uuid: info.uuid, props: info.properties)
                }
            }
        }
    }

    private func characteristicRow(uuid: String, props: CBCharacteristicProperties) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(shortUUID(uuid))
                    .font(.system(.subheadline, design: .monospaced).bold())
                Spacer()
                Text(propertyString(props))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let data = ble.diagValues[uuid] {
                Text("hex: \(data.hex)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let ascii = data.printableASCII {
                    Text("ascii: \(ascii)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            } else {
                Text("(no value read)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var logSection: some View {
        Section("Log") {
            if ble.diagLog.isEmpty {
                Text("No activity yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(ble.diagLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Helpers

    private func shortUUID(_ uuid: String) -> String {
        // Collapse the long Flashback 128-bit UUIDs to their short form when possible
        uuid.count > 8 ? uuid : uuid
    }

    private func propertyString(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("R") }
        if p.contains(.write) { parts.append("W") }
        if p.contains(.writeWithoutResponse) { parts.append("Wnr") }
        if p.contains(.notify) { parts.append("N") }
        if p.contains(.indicate) { parts.append("I") }
        return parts.joined(separator: "/")
    }
}

private extension Data {
    var hex: String {
        isEmpty ? "(empty)" : map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// ASCII rendering with non-printable bytes shown as '.', or nil if nothing printable.
    var printableASCII: String? {
        guard !isEmpty else { return nil }
        let printableCount = filter { $0 >= 0x20 && $0 < 0x7f }.count
        guard printableCount > 0 else { return nil }
        return String(map { ($0 >= 0x20 && $0 < 0x7f) ? Character(UnicodeScalar($0)) : "." })
    }
}
