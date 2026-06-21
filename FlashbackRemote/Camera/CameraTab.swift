import SwiftUI

struct CameraTab: View {
    @EnvironmentObject var ble: BLEController
    @EnvironmentObject var vm: CameraViewModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var protocol_: ProtocolConfig
    @FocusState private var rollFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                scanSection
                if let camera = ble.discoveredCamera {
                    if let mfr = camera.manufacturerData {
                        firmwareAlertSection(version: mfr.firmwareVersion,
                                             status: effectiveStatus(mfr.firmwareVersion))
                    }
                    cameraInfoSection(camera)
                    rollSection
                    actionSection
                }
                if let error = ble.lastError {
                    errorSection(error)
                }
            }
            .refreshable {
                ble.refresh()
            }
            .onChange(of: ble.selfTest) { result in
                if case .passed = result,
                   let v = ble.discoveredCamera?.manufacturerData?.firmwareVersion {
                    settings.markFirmwareLocallyConfirmed(v)
                }
            }
            .navigationTitle("Flashback Remote")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                    }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var scanSection: some View {
        switch ble.state {
        case .scanning:
            if ble.awaitingSelection || ble.discoveredCameras.count > 1 {
                Section("Select a camera") {
                    ForEach(ble.discoveredCameras) { camera in
                        Button {
                            ble.connect(toID: camera.id)
                        } label: {
                            HStack {
                                Image(systemName: "camera")
                                VStack(alignment: .leading) {
                                    Text(camera.name)
                                    if let mfr = camera.manufacturerData {
                                        Text("Firmware \(mfr.firmwareVersion) · \(mfr.batteryPercent)%")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                rssiView(camera.rssi)
                            }
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Scanning for ONE35 V2…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .scanTimeout:
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No camera found", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                    Text("Wind the camera and try again")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Scan Again") { ble.startScan() }
                    #if DEBUG
                    mockButton
                    #endif
                }
            }
        case .idle:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Scan for Camera") { ble.startScan() }
                    #if DEBUG
                    mockButton
                    #endif
                }
            }
        case .connecting, .discoveringServices, .discoveringCharacteristics:
            Section {
                HStack {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text(ble.statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        case .connected, .authenticating, .writingRoll, .triggeringWiFi:
            EmptyView()
        case .failed:
            Section {
                Button("Scan Again") { ble.startScan() }
            }
        }
    }

    private func effectiveStatus(_ version: String) -> FirmwareStatus {
        if settings.locallyConfirmedFirmware.contains(version) { return .confirmed(version: version) }
        return protocol_.status(for: version)
    }

    @ViewBuilder
    private func firmwareAlertSection(version: String, status: FirmwareStatus) -> some View {
        switch status {
        case .unknown:
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.gray)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unknown firmware \(version)")
                            .font(.callout.bold())
                        Text("This version isn't in the protocol config yet. Run a quick compatibility test — it's non-destructive (no roll or WiFi changes).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                selfTestView(version: version)
            }
        case .broken:
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Firmware \(version) is known broken")
                            .font(.callout.bold())
                        Text("The roll write is known to fail on this firmware version. Check GitHub for updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("Check for app update",
                             destination: URL(string: "https://github.com/deknared/flashback-remote/releases")!)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
        case .confirmed, .untested:
            EmptyView()
        }
    }

    @ViewBuilder
    private func selfTestView(version: String) -> some View {
        switch ble.selfTest {
        case .idle:
            Button {
                ble.runCompatibilityTest()
            } label: {
                Label("Run Compatibility Test", systemImage: "checkmark.seal")
            }
            .disabled(ble.state != .connected)
        case .running:
            HStack {
                ProgressView().padding(.trailing, 4)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .passed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label("Compatible", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(msg).font(.caption).foregroundStyle(.secondary)
                Text("Marked as working on this device. Help others by reporting it:")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Report \(version) as working", destination: githubReportURL(version: version, working: true))
                    .font(.caption)
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label("Test failed", systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red)
                Text(msg).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { ble.runCompatibilityTest() }
                Link("Report \(version) issue", destination: githubReportURL(version: version, working: false))
                    .font(.caption)
            }
        }
    }

    private func githubReportURL(version: String, working: Bool) -> URL {
        let title = working
            ? "Firmware \(version) confirmed working"
            : "Firmware \(version) compatibility issue"
        let body = """
        Firmware version: \(version)
        App version: \(SettingsView.appVersion)
        Compatibility test: \(working ? "PASSED" : "FAILED")

        Suggested flashback-protocol.json entry:
        "\(version)": { "status": "\(working ? "confirmed_working" : "broken")", "testedDate": "\(Self.todayString)", "notes": "" }
        """
        var comps = URLComponents(string: "https://github.com/deknared/flashback-remote/issues/new")!
        comps.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body)
        ]
        return comps.url ?? URL(string: "https://github.com/deknared/flashback-remote/issues")!
    }

    static var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func cameraInfoSection(_ camera: DiscoveredCamera) -> some View {
        Section("Camera") {
            LabeledContent("Name", value: camera.name)
            LabeledContent("Signal") {
                rssiView(camera.rssi)
            }
            if let mfr = camera.manufacturerData {
                LabeledContent("Firmware") {
                    firmwareBadge(version: mfr.firmwareVersion,
                                      status: effectiveStatus(mfr.firmwareVersion))
                }
                LabeledContent("Battery", value: "\(mfr.batteryPercent)%")
                LabeledContent("Shots remaining", value: "\(mfr.mediaRemaining)")
            }
            LabeledContent("Film wound") {
                Image(systemName: camera.isWound ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(camera.isWound ? .green : .red)
            }
        }
    }

    private var rollSection: some View {
        Section("Roll Configuration") {
            HStack {
                Text("Frames")
                Spacer()
                TextField("", value: $vm.rollLength, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .focused($rollFieldFocused)
                    .onChange(of: vm.rollLength) { val in
                        vm.rollLength = min(max(val, 1), 99)
                    }
                Stepper("", value: $vm.rollLength, in: 1...99)
                    .labelsHidden()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { rollFieldFocused = false }
            }
        }
    }

    private var actionSection: some View {
        Section {
            switch ble.state {
            case .authenticating:
                HStack {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text("Authenticating…")
                }
            case .writingRoll:
                HStack {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text("Writing roll config…")
                }
            case .triggeringWiFi:
                HStack {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text("Starting WiFi…")
                }
            case .connected:
                let isWound = ble.discoveredCamera?.isWound ?? false

                Button {
                    vm.setRollOnly(using: ble)
                } label: {
                    Label("Set Roll Length", systemImage: "film")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!isWound)

                Button {
                    vm.startWiFiOnly(using: ble)
                } label: {
                    Label("Start WiFi Transfer", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!isWound)

                Button {
                    vm.configure(using: ble)
                } label: {
                    Label("Set Roll + Start WiFi", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isWound)

                if !isWound {
                    Text("Wind the camera to enable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
    }

    private func errorSection(_ error: String) -> some View {
        Section {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    // MARK: Helper Views

    private func rssiView(_ rssi: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: rssiIconName(rssi))
            Text("\(rssi) dBm")
                .foregroundStyle(.secondary)
        }
    }

    private func rssiIconName(_ rssi: Int) -> String {
        switch rssi {
        case ..<( -80): return "wifi.exclamationmark"
        case ..<( -60): return "wifi"
        default:         return "wifi"
        }
    }

    #if DEBUG
    private var mockButton: some View {
        Button("Use Mock Camera (DEBUG)") { ble.activateMock() }
            .foregroundStyle(.orange)
            .font(.caption)
    }
    #endif

    @ViewBuilder
    private func firmwareBadge(version: String, status: FirmwareStatus) -> some View {
        HStack(spacing: 4) {
            Text(version)
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

