import Foundation

private let cameraUserAgent = "Flashback/225 CFNetwork/1410.1 Darwin/22.6.0"

struct DirectoryEntry: Decodable {
    let t: String        // "f" = file, "d" = directory
    let s: Int?          // size in bytes (absent for directories)
}

struct DirectoryListing: Decodable {
    let c: [String: DirectoryEntry]
}

final class HTTPDownloader {
    private let host: String
    private let session: URLSession
    private let progressDelegate = DownloadProgressDelegate()

    init(host: String = "192.168.4.1") {
        self.host = host
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": cameraUserAgent]
        // The camera AP is local and small files stall briefly between chunks;
        // a short request timeout aborts healthy transfers. Use a generous
        // per-request timeout but a tighter "no data at all" resource timeout.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6  // allow parallel file downloads
        session = URLSession(configuration: config,
                             delegate: progressDelegate,
                             delegateQueue: nil)
    }

    // MARK: - Directory listing

    func listFiles() async throws -> [CameraFile] {
        var result: [CameraFile] = []

        // Root directory (DNGs)
        let root = try await listDirectory(path: "/files/")
        for (name, entry) in root.c {
            if entry.t == "f" {
                let isDNG = name.lowercased().hasSuffix(".dng")
                result.append(CameraFile(
                    id: name,
                    filename: name,
                    sizeBytes: entry.s ?? 0,
                    isDNG: isDNG
                ))
            }
            // Recurse into UNPROCESSED_JPG directory
            if entry.t == "d" && name.uppercased() == "UNPROCESSED_JPG" {
                let jpgDir = try await listDirectory(path: "/files/\(name)/")
                for (jpgName, jpgEntry) in jpgDir.c where jpgEntry.t == "f" {
                    result.append(CameraFile(
                        id: "\(name)/\(jpgName)",
                        filename: jpgName,
                        sizeBytes: jpgEntry.s ?? 0,
                        isDNG: false
                    ))
                }
            }
        }

        return result.sorted { $0.filename < $1.filename }
    }

    // MARK: - Download

    func download(file: CameraFile, saveLocation: SaveLocation, progress: @escaping (Double) -> Void) async throws {
        let url = fileURL(for: file.id)

        let tempURL = try await downloadToTemp(url: url, lowercaseFallbackURL: lowercasedBasenameURL(url), progress: progress)
        try await save(from: tempURL, filename: file.filename, saveLocation: saveLocation)
    }

    // MARK: - Delete

    func delete(file: CameraFile) async throws {
        do {
            try await deleteRequest(url: fileURL(for: file.id))
        } catch {
            if let fallback = lowercasedBasenameURL(fileURL(for: file.id)) {
                try await deleteRequest(url: fallback)
            } else {
                throw error
            }
        }
    }

    private func deleteRequest(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Terminate

    func terminate() async throws {
        let url = URL(string: "http://\(host)/terminate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)  // best-effort
    }

    // MARK: - Private helpers

    private func listDirectory(path: String) async throws -> DirectoryListing {
        let url = URL(string: "http://\(host)\(path)")!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(DirectoryListing.self, from: data)
    }

    private func downloadToTemp(url: URL, lowercaseFallbackURL: URL?, progress: @escaping (Double) -> Void) async throws -> URL {
        do {
            return try await downloadFileToDisk(url: url, progress: progress)
        } catch {
            if let fallback = lowercaseFallbackURL {
                return try await downloadFileToDisk(url: fallback, progress: progress)
            }
            throw error
        }
    }

    // Streams the file directly to disk via a URLSessionDownloadTask — avoids
    // holding the entire file in memory (which crashed on large DNGs) and reports
    // incremental progress via the delegate so the UI bar moves smoothly.
    private func downloadFileToDisk(url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let (downloadedURL, response) = try await downloadWithProgress(url: url, progress: progress)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        // Move out of the system-managed temp location before iOS cleans it up.
        let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.moveItem(at: downloadedURL, to: stableURL)
        progress(1.0)
        return stableURL
    }

    private func downloadWithProgress(url: URL, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            progressDelegate.register(task: task, onProgress: progress) { result in
                continuation.resume(with: result)
            }
            task.resume()
        }
    }

    private func save(from tempURL: URL, filename: String, saveLocation: SaveLocation) async throws {
        switch saveLocation {
        case .photos:
            try await saveToPhotos(tempURL: tempURL, filename: filename)
        case .files, .icloud:
            try saveToDocuments(tempURL: tempURL, filename: filename, useICloud: saveLocation == .icloud)
        }
    }

    private func saveToPhotos(tempURL: URL, filename: String) async throws {
        // PHPhotoLibrary save — bridged to async
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PhotosSaver.save(tempURL: tempURL, filename: filename) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func saveToDocuments(tempURL: URL, filename: String, useICloud: Bool) throws {
        let dest = try FlashbackStorage.destinationURL(filename: filename, useICloud: useICloud)
        try FileManager.default.moveItem(at: tempURL, to: dest)
    }

    private func fileURL(for id: String) -> URL {
        URL(string: "http://\(host)/files/\(id)")!
    }

    // Lowercases only the basename (e.g. SN..._00240.DNG → ...dng), preserving the
    // directory portion's case — the camera accepts lowercase basenames as a fallback.
    private func lowercasedBasenameURL(_ url: URL) -> URL? {
        let dir = url.deletingLastPathComponent()
        let lowerName = url.lastPathComponent.lowercased()
        guard lowerName != url.lastPathComponent else { return nil }
        return dir.appendingPathComponent(lowerName)
    }
}

// MARK: - Download progress delegate

// URLSessionDownloadTask reports byte-level progress and writes directly to disk.
// We immediately copy the finished file to our own temp location inside the
// didFinishDownloadingTo callback, because the delegate-provided URL is deleted
// the moment that method returns.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private struct Handlers {
        let onProgress: (Double) -> Void
        let completion: (Result<(URL, URLResponse), Error>) -> Void
    }
    private var handlers: [Int: Handlers] = [:]
    private let lock = NSLock()

    func register(task: URLSessionDownloadTask,
                  onProgress: @escaping (Double) -> Void,
                  completion: @escaping (Result<(URL, URLResponse), Error>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers[task.taskIdentifier] = Handlers(onProgress: onProgress, completion: completion)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock(); let h = handlers[downloadTask.taskIdentifier]; lock.unlock()
        h?.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock(); let h = handlers[downloadTask.taskIdentifier]; lock.unlock()
        guard let h else { return }
        let response = downloadTask.response ?? URLResponse()
        // Copy synchronously — `location` is gone once this returns.
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: copy)
            h.completion(.success((copy, response)))
        } catch {
            h.completion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let h = handlers[task.taskIdentifier]; handlers[task.taskIdentifier] = nil; lock.unlock()
        if let error { h?.completion(.failure(error)) }
    }
}

// MARK: - Photos shim

import Photos

enum PhotosSaver {
    static func save(tempURL: URL, filename: String, completion: @escaping (Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges {
            // PHAssetCreationRequest correctly handles DNG (raw) and JPEG without conversion.
            // creationRequestForAssetFromImage would re-encode the file through ImageIO.
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            request.addResource(with: .photo, fileURL: tempURL, options: options)
        } completionHandler: { _, error in
            completion(error)
        }
    }
}
