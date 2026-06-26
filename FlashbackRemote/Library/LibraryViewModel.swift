import Foundation
import UIKit
import ImageIO
import CoreImage

// One entry in the Library — a captured frame, which may have a DNG, a JPEG, or
// both (same basename). Deleting an item removes every file for that basename.
struct LibraryItem: Identifiable, Hashable {
    let id: String          // group-relative path without extension (unique)
    let displayName: String
    let dngURL: URL?
    let jpegURL: URL?
    let date: Date
    let sizeBytes: Int

    // Prefer the JPEG for thumbnails (fast); fall back to raw-decoding the DNG.
    var thumbnailSourceURL: URL? { jpegURL ?? dngURL }
    var primaryURL: URL? { dngURL ?? jpegURL }
    var isRawOnly: Bool { jpegURL == nil && dngURL != nil }

    var sizeMB: String { String(format: "%.1f MB", Double(sizeBytes) / 1_048_576) }
}

// A group = a folder. Root-level files are the special "Ungrouped" group;
// each subfolder under the app folder is a named group.
struct LibraryGroup: Identifiable {
    let id: String          // ungroupedID for root, else the folder name
    let name: String        // "Ungrouped" or the folder name
    let isUngrouped: Bool
    let folderURL: URL
    var items: [LibraryItem]
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var groups: [LibraryGroup] = []
    @Published var isLoading = false

    static let ungroupedID = "__ungrouped__"

    private let imageExts: Set<String> = ["dng", "jpg", "jpeg"]

    var allItems: [LibraryItem] { groups.flatMap(\.items) }

    func items(inGroupID id: String) -> [LibraryItem] {
        groups.first { $0.id == id }?.items ?? []
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        let root = FlashbackStorage.localFolder
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else {
            groups = []
            return
        }

        var rootFiles: [URL] = []
        var subdirs: [URL] = []
        for e in entries {
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir == true { subdirs.append(e) } else { rootFiles.append(e) }
        }

        var result: [LibraryGroup] = []

        let ungrouped = buildItems(from: rootFiles, groupPrefix: "")
        if !ungrouped.isEmpty {
            result.append(LibraryGroup(id: Self.ungroupedID, name: "Ungrouped",
                                       isUngrouped: true, folderURL: root, items: ungrouped))
        }

        for dir in subdirs.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let items = buildItems(from: files, groupPrefix: dir.lastPathComponent)
            result.append(LibraryGroup(id: dir.lastPathComponent, name: dir.lastPathComponent,
                                       isUngrouped: false, folderURL: dir, items: items))
        }

        groups = result
    }

    private func buildItems(from urls: [URL], groupPrefix: String) -> [LibraryItem] {
        struct Acc { var dng: URL?; var jpg: URL?; var date: Date; var size: Int }
        var acc: [String: Acc] = [:]
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard imageExts.contains(ext) else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            let rv = try? url.resourceValues(forKeys: keys)
            let date = rv?.contentModificationDate ?? .distantPast
            let size = rv?.fileSize ?? 0
            var g = acc[base] ?? Acc(dng: nil, jpg: nil, date: .distantPast, size: 0)
            if ext == "dng" { g.dng = url } else { g.jpg = url }
            g.size += size
            if date > g.date { g.date = date }
            acc[base] = g
        }
        return acc.map { base, g in
            LibraryItem(id: groupPrefix.isEmpty ? base : "\(groupPrefix)/\(base)",
                        displayName: (g.dng ?? g.jpg)?.lastPathComponent ?? base,
                        dngURL: g.dng, jpegURL: g.jpg, date: g.date, sizeBytes: g.size)
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: Mutations

    func delete(_ item: LibraryItem) {
        removeFiles(for: [item])
        load()
    }

    func delete(ids: Set<String>) {
        removeFiles(for: allItems.filter { ids.contains($0.id) })
        load()
    }

    private func removeFiles(for items: [LibraryItem]) {
        for item in items {
            for url in [item.dngURL, item.jpegURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
            ThumbnailCache.shared.remove(item.id)
        }
    }

    /// Move the given items into a (new or existing) named group folder.
    func group(ids: Set<String>, intoName rawName: String) {
        guard let name = sanitized(rawName) else { return }
        let target = FlashbackStorage.localFolder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for item in allItems where ids.contains(item.id) {
            moveFiles([item.dngURL, item.jpegURL].compactMap { $0 }, into: target)
            ThumbnailCache.shared.remove(item.id)
        }
        load()
    }

    /// Rename a group. Renaming "Ungrouped" creates a folder and moves the root
    /// files into it; renaming a named group renames (or merges) its folder.
    func rename(group: LibraryGroup, to rawName: String) {
        guard let name = sanitized(rawName) else { return }
        let root = FlashbackStorage.localFolder
        let target = root.appendingPathComponent(name, isDirectory: true)

        if group.isUngrouped {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for item in group.items {
                moveFiles([item.dngURL, item.jpegURL].compactMap { $0 }, into: target)
                ThumbnailCache.shared.remove(item.id)
            }
        } else if target.path != group.folderURL.path {
            if FileManager.default.fileExists(atPath: target.path) {
                // Merge into an existing folder of that name.
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for item in group.items {
                    moveFiles([item.dngURL, item.jpegURL].compactMap { $0 }, into: target)
                    ThumbnailCache.shared.remove(item.id)
                }
                try? FileManager.default.removeItem(at: group.folderURL)
            } else {
                try? FileManager.default.moveItem(at: group.folderURL, to: target)
                // Thumbnail keys included the old folder name; clear them.
                group.items.forEach { ThumbnailCache.shared.remove($0.id) }
            }
        }
        load()
    }

    private func moveFiles(_ urls: [URL], into folder: URL) {
        for url in urls {
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.moveItem(at: url, to: dest)
        }
    }

    private func sanitized(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? nil : cleaned
    }

    func fileURLs(for ids: Set<String>) -> [URL] {
        allItems.filter { ids.contains($0.id) }
            .flatMap { [$0.dngURL, $0.jpegURL].compactMap { $0 } }
    }

    var showsRawBadges: Bool {
        allItems.contains { $0.dngURL == nil } && allItems.contains { $0.dngURL != nil }
    }
}

// MARK: - Thumbnail cache + decoding

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private let dir: URL

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlashbackThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func image(for key: String) -> UIImage? {
        if let mem = cache.object(forKey: key as NSString) { return mem }
        // Fall back to the on-disk render so re-launching the Library is instant.
        if let data = try? Data(contentsOf: fileURL(key)), let img = UIImage(data: data) {
            cache.setObject(img, forKey: key as NSString)
            return img
        }
        return nil
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: fileURL(key))
        }
    }

    func remove(_ key: String) {
        cache.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: fileURL(key))
    }

    private func fileURL(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }
}

enum ImageDecoder {
    // ONE35 DNGs use our ported Bayer decoder (CIRAWFilter mis-reads them).
    // JPEGs use the fast ImageIO thumbnail path.
    static func thumbnail(url: URL, maxPixel: CGFloat) -> UIImage? {
        if url.pathExtension.lowercased() == "dng" {
            return One35DNGDecoder.decode(url: url, maxDimension: Int(maxPixel))
                ?? sourceThumbnail(url: url, maxPixel: maxPixel)
        }
        return sourceThumbnail(url: url, maxPixel: maxPixel)
    }

    static func fullImage(url: URL, maxPixel: CGFloat = 2400) -> UIImage? {
        if url.pathExtension.lowercased() == "dng" {
            return One35DNGDecoder.decode(url: url, maxDimension: 2072)
                ?? UIImage(contentsOfFile: url.path)
        }
        return sourceThumbnail(url: url, maxPixel: maxPixel) ?? UIImage(contentsOfFile: url.path)
    }

    private static func sourceThumbnail(url: URL, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
