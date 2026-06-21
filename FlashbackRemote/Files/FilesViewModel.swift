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
    case done(count: Int)
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

    private var downloader: HTTPDownloader?

    func loadFiles(host: String = "192.168.4.1") {
        Task { await loadFilesAsync(host: host) }
    }

    func loadFilesAsync(host: String = "192.168.4.1") async {
        downloadState = .listing
        let dl = HTTPDownloader(host: host)
        downloader = dl
        do {
            files = try await dl.listFiles()
            downloadState = .idle
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    func downloadAll(saveLocation: SaveLocation, dngOnly: Bool = false, forceDelete: Bool = false, host: String = "192.168.4.1") {
        guard !files.isEmpty else { return }
        let dl = HTTPDownloader(host: host)
        downloader = dl
        Notifier.requestAuthorization()

        let toDownload = dngOnly ? files.filter(\.isDNG) : files
        let toDeleteOnly = dngOnly ? files.filter { !$0.isDNG } : []
        let deleteDownloaded = deleteAfterDownload || forceDelete

        downloadState = .downloading(completed: 0, total: toDownload.count)
        fileProgress = [:]

        // Ask iOS for extra time so a brief lock mid-transfer doesn't suspend us
        // immediately. This is best-effort (a few minutes at most); for very large
        // batches the screen should stay on. The completion notification fires
        // regardless once the work finishes.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "FlashbackDownload") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        // Keep the screen awake so the transfer keeps running if the user sets the
        // phone down. (A manual lock still suspends us — the camera's no-internet
        // WiFi tends to drop on lock, so true background transfer isn't reliable.)
        UIApplication.shared.isIdleTimerDisabled = true

        Task {
            var completed = 0
            var failed = 0
            var deletedIDs: Set<String> = []
            for file in toDownload {
                do {
                    try await dl.download(file: file, saveLocation: saveLocation) { progress in
                        Task { @MainActor in
                            self.fileProgress[file.id] = progress
                        }
                    }
                    completed += 1
                } catch {
                    failed += 1
                }
                downloadState = .downloading(completed: completed, total: toDownload.count)
            }

            // Always delete camera JPEGs when dngOnly is on
            for file in toDeleteOnly {
                if (try? await dl.delete(file: file)) != nil { deletedIDs.insert(file.id) }
            }

            if deleteDownloaded && failed == 0 {
                for file in toDownload {
                    if (try? await dl.delete(file: file)) != nil { deletedIDs.insert(file.id) }
                }
            }

            // Prune deleted files from the list so the UI reflects what remains on
            // the camera without another network round-trip.
            if !deletedIDs.isEmpty {
                files.removeAll { deletedIDs.contains($0.id) }
            }

            await terminate(host: host)
            downloadState = .done(count: completed)
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
            downloadState = .done(count: completed)
            Notifier.notifyDownloadComplete(count: completed, deleted: deleted)
        }
    }

    func onWiFiReady(mock: Bool = false) {
        switchToFilesTab = true
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
