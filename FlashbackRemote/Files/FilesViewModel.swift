import Foundation
import Combine
import UIKit

struct CameraFile: Identifiable, Hashable {
    let id: String  // filename
    let filename: String
    let sizeBytes: Int
    let isDNG: Bool

    var sizeMB: String {
        let mb = Double(sizeBytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}

enum DownloadState {
    case idle
    case listing
    case downloading(completed: Int, total: Int)
    case done(saved: Int, failed: Int)
    case failed(String)
}

@MainActor
final class FilesViewModel: ObservableObject {
    @Published var files: [CameraFile] = []
    @Published var downloadState: DownloadState = .idle
    @Published var fileProgress: [String: Double] = [:]
    @Published var switchToFilesTab = false
    @Published var deleteAfterDownload = false
    @Published var showDeleteConfirm = false

    // True once a file list has loaded at least once this WiFi session — used to
    // hide the "Load Files" button after the first successful load.
    @Published var filesLoaded = false

    // Live transfer stats for the downloading UI.
    @Published var transferSpeedMBps: Double = 0
    @Published var elapsedSeconds: Int = 0

    // Files that failed in the last transfer, for the "Retry failed" action.
    @Published var failedFiles: [CameraFile] = []

    private var downloader: HTTPDownloader?
    private var lastSaveLocation: SaveLocation = .files

    func loadFiles(host: String = "192.168.4.1") {
        Task { await loadFilesAsync(host: host) }
    }

    private var autoLoading = false
    // Poll for the camera's HTTP API becoming reachable (the phone joining the
    // WiFi), then list files automatically — no manual "Load Files" tap.
    func autoLoadWhenReachable(host: String = "192.168.4.1") {
        guard !filesLoaded, !autoLoading else { return }
        autoLoading = true
        Task {
            defer { autoLoading = false }
            let dl = HTTPDownloader(host: host)
            for _ in 0..<30 {
                if filesLoaded { return }
                if await dl.reachable() {
                    if !filesLoaded { await loadFilesAsync(host: host) }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func loadFilesAsync(host: String = "192.168.4.1") async {
        downloadState = .listing
        let dl = HTTPDownloader(host: host)
        downloader = dl
        do {
            files = try await dl.listFiles()
            filesLoaded = true
            downloadState = .idle
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    func downloadAll(saveLocation: SaveLocation, dngOnly: Bool = false, forceDelete: Bool = false, concurrency: Int = 3, host: String = "192.168.4.1") {
        guard !files.isEmpty else { return }
        let toDownload = dngOnly ? files.filter(\.isDNG) : files
        let toDeleteOnly = dngOnly ? files.filter { !$0.isDNG } : []
        runDownload(list: toDownload,
                    deleteOnly: toDeleteOnly,
                    saveLocation: saveLocation,
                    deleteDownloaded: deleteAfterDownload || forceDelete,
                    concurrency: concurrency,
                    host: host)
    }

    func retryFailed(concurrency: Int = 3, host: String = "192.168.4.1") {
        let list = failedFiles
        guard !list.isEmpty else { return }
        runDownload(list: list,
                    deleteOnly: [],
                    saveLocation: lastSaveLocation,
                    deleteDownloaded: false,
                    concurrency: concurrency,
                    host: host)
    }

    private func runDownload(list: [CameraFile],
                             deleteOnly: [CameraFile],
                             saveLocation: SaveLocation,
                             deleteDownloaded: Bool,
                             concurrency: Int,
                             host: String) {
        guard !list.isEmpty else { return }
        let dl = HTTPDownloader(host: host)
        downloader = dl
        lastSaveLocation = saveLocation
        Notifier.requestAuthorization()

        downloadState = .downloading(completed: 0, total: list.count)
        fileProgress = [:]
        failedFiles = []
        transferSpeedMBps = 0
        elapsedSeconds = 0
        let start = Date()

        // Best-effort extra background time + keep the screen awake during transfer.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "FlashbackDownload") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true

        let maxConcurrent = min(max(concurrency, 1), 6)

        Task {
            var completed = 0
            var completedBytes = 0
            var failedList: [CameraFile] = []
            var deletedIDs: Set<String> = []

            var next = 0
            await withTaskGroup(of: (CameraFile, Bool).self) { group in
                func addTask() {
                    guard next < list.count else { return }
                    let file = list[next]
                    next += 1
                    group.addTask {
                        do {
                            try await dl.download(file: file, saveLocation: saveLocation) { progress in
                                Task { @MainActor in self.fileProgress[file.id] = progress }
                            }
                            return (file, true)
                        } catch {
                            return (file, false)
                        }
                    }
                }
                for _ in 0..<min(maxConcurrent, list.count) { addTask() }
                for await (file, ok) in group {
                    if ok {
                        completed += 1
                        completedBytes += file.sizeBytes
                    } else {
                        failedList.append(file)
                    }
                    let elapsed = max(Date().timeIntervalSince(start), 0.001)
                    elapsedSeconds = Int(elapsed)
                    transferSpeedMBps = Double(completedBytes) / 1_048_576 / elapsed
                    downloadState = .downloading(completed: completed, total: list.count)
                    addTask()
                }
            }

            // Always delete camera JPEGs when dngOnly is on
            for file in deleteOnly {
                if (try? await dl.delete(file: file)) != nil { deletedIDs.insert(file.id) }
            }

            // Only auto-delete the downloaded files if every one succeeded.
            if deleteDownloaded && failedList.isEmpty {
                for file in list {
                    if (try? await dl.delete(file: file)) != nil { deletedIDs.insert(file.id) }
                }
            }

            if !deletedIDs.isEmpty {
                files.removeAll { deletedIDs.contains($0.id) }
            }

            failedFiles = failedList
            await terminate(host: host)
            downloadState = .done(saved: completed, failed: failedList.count)
            Notifier.notifyDownloadComplete(count: completed, deleted: deletedIDs.count)

            UIApplication.shared.isIdleTimerDisabled = false
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
    }

    // Import files picked from the Files app (e.g. a USB-connected camera). The
    // picker hands back in-place, security-scoped URLs, so we copy each into the
    // chosen save location and — when deleteOriginals is set — delete the source,
    // mirroring the WiFi "copy + delete" flow.
    func importPicked(urls: [URL], saveLocation: SaveLocation, deleteOriginals: Bool) {
        guard !urls.isEmpty else { return }
        downloadState = .downloading(completed: 0, total: urls.count)
        Notifier.requestAuthorization()
        Task {
            var completed = 0
            var deleted = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await ImportedFileSaver.save(tempURL: url,
                                                     filename: url.lastPathComponent,
                                                     saveLocation: saveLocation)
                    completed += 1
                    if deleteOriginals, (try? FileManager.default.removeItem(at: url)) != nil {
                        deleted += 1
                    }
                } catch {
                    // Skip files that fail; continue with the rest.
                }
                downloadState = .downloading(completed: completed, total: urls.count)
            }
            downloadState = .done(saved: completed, failed: 0)
            Notifier.notifyDownloadComplete(count: completed, deleted: deleted)
        }
    }

    func onWiFiReady(mock: Bool = false) {
        switchToFilesTab = true
        filesLoaded = false   // show "Load Files" again for the new session
        #if DEBUG
        if mock {
            injectMockFiles()
        }
        #endif
        // Do not call loadFiles() here — the phone hasn't joined the camera
        // WiFi network yet. FilesTab shows manual join instructions; loadFiles()
        // runs only when the user taps "Load Files" after joining ONE35 in Settings.
    }

    #if DEBUG
    func injectMockFiles() {
        files = [
            CameraFile(id: "SN554191302_00240.dng", filename: "SN554191302_00240.dng", sizeBytes: 16_777_216, isDNG: true),
            CameraFile(id: "SN554191302_00241.dng", filename: "SN554191302_00241.dng", sizeBytes: 15_728_640, isDNG: true),
            CameraFile(id: "SN554191302_00242.dng", filename: "SN554191302_00242.dng", sizeBytes: 16_252_928, isDNG: true),
            CameraFile(id: "UNPROCESSED_JPG/SN554191302_00240.JPG", filename: "SN554191302_00240.JPG", sizeBytes: 3_145_728, isDNG: false),
            CameraFile(id: "UNPROCESSED_JPG/SN554191302_00241.JPG", filename: "SN554191302_00241.JPG", sizeBytes: 2_883_584, isDNG: false),
        ]
        downloadState = .idle
    }
    #endif

    // MARK: Private

    private func terminate(host: String) async {
        try? await HTTPDownloader(host: host).terminate()
    }
}

// Saves a local file (e.g. one imported via the document picker) to the chosen
// destination. Mirrors HTTPDownloader's save paths so imported and downloaded
// files land in the same place.
enum ImportedFileSaver {
    static func save(tempURL: URL, filename: String, saveLocation: SaveLocation) async throws {
        switch saveLocation {
        case .photos:
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PhotosSaver.save(tempURL: tempURL, filename: filename) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        case .files, .icloud:
            let dest = try FlashbackStorage.destinationURL(filename: filename,
                                                           useICloud: saveLocation == .icloud)
            try FileManager.default.copyItem(at: tempURL, to: dest)
        }
    }
}

// Shared resolver for the on-device save folder, used by both the WiFi downloader
// and the USB importer so the destination logic lives in one place.
enum FlashbackStorage {
    // The app's local on-device folder (On My iPhone → Flashback Remote). The
    // Library reads only this location.
    static var localFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flashback Remote", isDirectory: true)
    }

    static func destinationURL(filename: String, useICloud: Bool) throws -> URL {
        let baseURL: URL
        if useICloud, let icloud = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            baseURL = icloud.appendingPathComponent("Documents/Flashback Remote", isDirectory: true)
        } else {
            baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Flashback Remote", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let dest = baseURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        return dest
    }
}
