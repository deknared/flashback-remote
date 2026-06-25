import SwiftUI
import CoreImage

struct FilesTab: View {
    @EnvironmentObject var ble: BLEController
    @EnvironmentObject var vm: FilesViewModel
    @EnvironmentObject var settings: SettingsStore
    @State private var copiedPassword = false
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Group {
                switch vm.downloadState {
                case .idle:
                    idleView
                case .listing:
                    loadingView("Loading file list…")
                case .downloading(let completed, let total):
                    downloadingView(completed: completed, total: total)
                case .done(let saved, let failed):
                    doneView(saved: saved, failed: failed)
                case .failed(let msg):
                    errorView(msg)
                }
            }
            .navigationTitle("Files")
            .sheet(isPresented: $showImporter) {
                DocumentPicker { urls in
                    vm.importPicked(urls: urls,
                                    saveLocation: settings.saveLocation,
                                    deleteOriginals: settings.alwaysDeleteFromCamera)
                }
            }
        }
    }

    // MARK: Sub-views

    private var idleView: some View {
        Group {
            if case .up(let ip) = ble.wifiStatus {
                filesReadyView(ip: ip)
            } else {
                waitingForWiFiView
            }
        }
    }

    private var waitingForWiFiView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Waiting for Camera WiFi")
                .font(.headline)
            Text("Go to the Camera tab and tap Start WiFi Transfer")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Divider().padding(.vertical, 8)

            Text("Or import over USB")
                .font(.subheadline.bold())
            Text(settings.alwaysDeleteFromCamera
                 ? "Connect the camera with a cable, pick the DNGs, and they'll be copied then deleted from the camera."
                 : "Connect the camera to your iPhone with a cable, then pick the DNGs from the Files browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                showImporter = true
            } label: {
                Label("Import from Files (USB)", systemImage: "cable.connector")
            }
            .buttonStyle(.bordered)

            if !settings.shortcutName.isEmpty {
                Button {
                    runShortcut(settings.shortcutName)
                } label: {
                    Label("Run \"\(settings.shortcutName)\"", systemImage: "bolt.fill")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }

    private func runShortcut(_ name: String) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else { return }
        UIApplication.shared.open(url)
    }

    private func filesReadyView(ip: String) -> some View {
        let visibleFiles = settings.dngOnly ? vm.files.filter(\.isDNG) : vm.files
        let dngs = visibleFiles.filter(\.isDNG)
        let jpgs = visibleFiles.filter { !$0.isDNG }

        return List {
            // The join banner (credentials + Load Files) is only useful before the
            // first successful load — hide it once files are listed.
            if !vm.filesLoaded {
                Section {
                    wifiJoinBanner(ip: ip)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if visibleFiles.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("No Files")
                                .font(.headline)
                            Text("The camera has no photos to transfer")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 24)
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                if !dngs.isEmpty {
                    Section("DNG (\(dngs.count))") {
                        ForEach(dngs) { file in fileRow(file) }
                    }
                }
                if !jpgs.isEmpty {
                    Section(header: VStack(alignment: .leading, spacing: 2) {
                        Text("JPEG (\(jpgs.count))")
                        Text("Preview JPEGs alongside each DNG")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }) {
                        ForEach(jpgs) { file in fileRow(file) }
                    }
                }

                Section {
                    if settings.alwaysDeleteFromCamera {
                        Label("Files will be deleted from the camera (Settings)", systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Delete from camera after download", isOn: $vm.deleteAfterDownload)
                        if settings.dngOnly {
                            Text("JPEGs are always deleted in DNGs-only mode. Turn the toggle on to also delete the DNGs after they download.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        // Only prompt for the per-transfer toggle; the always-delete
                        // setting is a deliberate opt-in, so it runs without asking.
                        if vm.deleteAfterDownload && !settings.alwaysDeleteFromCamera {
                            vm.showDeleteConfirm = true
                        } else {
                            vm.downloadAll(saveLocation: settings.saveLocation,
                                           dngOnly: settings.dngOnly,
                                           forceDelete: settings.alwaysDeleteFromCamera,
                                           concurrency: settings.downloadConcurrency)
                        }
                    } label: {
                        Label(
                            settings.dngOnly
                                ? "Download \(dngs.count) DNG\(dngs.count == 1 ? "" : "s")"
                                : "Download All (\(visibleFiles.count) files)",
                            systemImage: "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section { Color.clear.frame(height: 70) }
                .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .task(id: vm.filesLoaded) {
            if !vm.filesLoaded { vm.autoLoadWhenReachable() }
        }
        .confirmationDialog(
            "Delete \(vm.files.count) files from camera after download?",
            isPresented: $vm.showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete after download", role: .destructive) {
                vm.downloadAll(saveLocation: settings.saveLocation,
                               dngOnly: settings.dngOnly,
                               forceDelete: settings.alwaysDeleteFromCamera,
                               concurrency: settings.downloadConcurrency)
            }
            Button("Cancel", role: .cancel) { vm.deleteAfterDownload = false }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func wifiJoinBanner(ip: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera WiFi is ready")
                .font(.headline)

            if let ssid = ble.apSSID, let pw = ble.apPassword {
                HStack(alignment: .top, spacing: 16) {
                    // WiFi QR code — for joining from a *second* device. Tap to copy
                    // the password when you're on this same phone.
                    if let qr = makeWiFiQR(ssid: ssid, password: pw) {
                        qr
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                            .padding(6)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        credRow(label: "Network", value: ssid)
                        credRow(label: "Password", value: pw)
                    }
                }

                // One-device flow: copy the password so it can be pasted in the
                // WiFi join sheet. iOS has no public API to deep-link straight to
                // WiFi settings, so the user opens Settings manually.
                Button {
                    UIPasteboard.general.string = pw
                    copiedPassword = true
                } label: {
                    Label(copiedPassword ? "Password Copied" : "Copy Password",
                          systemImage: copiedPassword ? "checkmark.circle.fill" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("Open **Settings → WiFi**, select **\(ssid)**, and paste the password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                vm.loadFiles()
            } label: {
                Label("Load Files", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06)))
        .padding(.horizontal, 4)
    }

    private func credRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced).bold())
                .textSelection(.enabled)
        }
    }

    private func fileRow(_ file: CameraFile) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(file.filename).font(.system(.footnote, design: .monospaced))
                Text(file.sizeMB).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = vm.fileProgress[file.id] {
                ProgressView(value: p)
                    .frame(width: 60)
            }
        }
    }

    private func loadingView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(msg).foregroundStyle(.secondary)
        }
    }

    private func downloadingView(completed: Int, total: Int) -> some View {
        VStack(spacing: 16) {
            Text("Downloading…")
                .font(.headline)
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .padding(.horizontal)
            Text("\(completed) of \(total) files")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label(String(format: "%.1f MB/s", vm.transferSpeedMBps), systemImage: "speedometer")
                Label(elapsedString(vm.elapsedSeconds), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func elapsedString(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private func doneView(saved: Int, failed: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(failed == 0 ? .green : .orange)
            Text("\(saved) saved\(failed > 0 ? " · \(failed) failed" : "")")
                .font(.title2)
            Text(savedLocationHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if failed > 0 {
                Button {
                    vm.retryFailed(concurrency: settings.downloadConcurrency)
                } label: {
                    Label("Retry \(failed) failed", systemImage: "arrow.clockwise")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Done") { vm.downloadState = .idle }
        }
        .padding()
    }

    private var savedLocationHint: String {
        switch settings.saveLocation {
        case .photos: return "Saved to Photos → Recents"
        case .files:  return "Files app → On My iPhone → Flashback Remote"
        case .icloud: return "Files app → iCloud Drive → Flashback Remote"
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(msg).multilineTextAlignment(.center)
            Button("Retry") { vm.loadFiles() }
        }
        .padding()
    }

    // MARK: WiFi QR code

    private func makeWiFiQR(ssid: String, password: String) -> Image? {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: ";", with: "\\;")
             .replacingOccurrences(of: ",", with: "\\,")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let payload = "WIFI:T:WPA;S:\(esc(ssid));P:\(esc(password));;"
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(uiImage: UIImage(cgImage: cgImage))
    }
}
