import Foundation
import UIKit
import ImageIO
import CoreImage

// One entry in the Library — a captured frame, which may have a DNG, a JPEG, or
// both (same basename). Deleting an item removes every file for that basename.
struct LibraryItem: Identifiable, Hashable, Sendable {
    let id: String          // group-relative path without extension (unique)
    let displayName: String
    let dngURL: URL?
    let jpegURL: URL?
    let date: Date           // file modification date (transfer time) — sort fallback
    let captureDate: Date?   // EXIF shot date, when readable
    let sizeBytes: Int

    // Prefer the JPEG for thumbnails (fast); fall back to raw-decoding the DNG.
    var thumbnailSourceURL: URL? { jpegURL ?? dngURL }
    var primaryURL: URL? { dngURL ?? jpegURL }
    var isRawOnly: Bool { jpegURL == nil && dngURL != nil }

    // The date to actually sort/display by: when the shot was taken if known,
    // else falls back to when the file landed on the phone.
    var sortDate: Date { captureDate ?? date }

    var sizeMB: String { String(format: "%.1f MB", Double(sizeBytes) / 1_048_576) }
}

// How photos are ordered inside every group. One app-wide setting, persisted.
enum LibrarySortOrder: String, CaseIterable, Sendable {
    case newestFirst, oldestFirst, nameAZ, nameZA

    var label: String {
        switch self {
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        case .nameAZ:      return "Name A–Z"
        case .nameZA:      return "Name Z–A"
        }
    }

    func areInOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        switch self {
        case .newestFirst: return a.sortDate > b.sortDate
        case .oldestFirst: return a.sortDate < b.sortDate
        case .nameAZ: return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        case .nameZA: return a.displayName.localizedStandardCompare(b.displayName) == .orderedDescending
        }
    }
}

// A group = a folder. Root-level files are the special "Ungrouped" group;
// each subfolder under the app folder is a named group.
struct LibraryGroup: Identifiable, Sendable {
    let id: String          // ungroupedID for root, else the folder name
    let name: String        // "Ungrouped" or the folder name
    let isUngrouped: Bool
    let folderURL: URL
    var items: [LibraryItem]
}

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var groups: [LibraryGroup] = []
    @Published var binItems: [LibraryItem] = []
    @Published var isLoading = false

    /// Default order for every group that hasn't been given its own.
    @Published var sortOrder: LibrarySortOrder =
        LibrarySortOrder(rawValue: UserDefaults.standard.string(forKey: "librarySortOrder") ?? "") ?? .newestFirst {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "librarySortOrder")
            resortAll()
        }
    }

    /// Per-group overrides, so one roll can be ordered differently from the rest.
    @Published private(set) var groupSortOverrides: [String: LibrarySortOrder] =
        (UserDefaults.standard.dictionary(forKey: "groupSortOverrides") as? [String: String] ?? [:])
            .compactMapValues { LibrarySortOrder(rawValue: $0) }

    func sortOrder(forGroupID id: String) -> LibrarySortOrder {
        groupSortOverrides[id] ?? sortOrder
    }

    /// Passing nil clears the override so the group follows the global default.
    func setSortOrder(_ order: LibrarySortOrder?, forGroupID id: String) {
        if let order { groupSortOverrides[id] = order } else { groupSortOverrides.removeValue(forKey: id) }
        UserDefaults.standard.set(groupSortOverrides.mapValues(\.rawValue), forKey: "groupSortOverrides")
        resortAll()
    }

    private func resortAll() {
        // Re-sort in place — no need to rescan the filesystem.
        for i in groups.indices {
            groups[i].items.sort(by: sortOrder(forGroupID: groups[i].id).areInOrder)
        }
    }

    static let ungroupedID = "__ungrouped__"
    static let recycleBinID = "__recyclebin__"

    // static so the off-main scan functions can reach them
    nonisolated static let imageExts: Set<String> = ["dng", "jpg", "jpeg"]
    nonisolated static let binDelimiter = "##"
    nonisolated static var binURL: URL { FlashbackStorage.localFolder.appendingPathComponent(".RecycleBin", isDirectory: true) }

    private var binURL: URL { Self.binURL }
    private var binDelimiter: String { Self.binDelimiter }

    var allItems: [LibraryItem] { groups.flatMap(\.items) }
    var binItemIDs: Set<String> { Set(binItems.map(\.id)) }
    var hasBin: Bool { !binItems.isEmpty }

    func items(inGroupID id: String) -> [LibraryItem] {
        if id == Self.recycleBinID { return binItems }
        return groups.first { $0.id == id }?.items ?? []
    }

    /// Rescan the library folder. The actual filesystem work (directory
    /// enumeration + per-file EXIF header reads) happens off the main thread —
    /// it used to run synchronously on the main actor on every tab appearance,
    /// which visibly hitched once a library grew past a few dozen photos.
    func load() {
        guard !isLoading else { return }   // coalesce overlapping refreshes
        isLoading = true
        let order = sortOrder
        let overrides = groupSortOverrides
        let retention = UserDefaults.standard.object(forKey: "recycleRetentionMonths") as? Int ?? 1
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.scan(sortOrder: order, overrides: overrides, retentionMonths: retention)
            }.value
            self.groups = snapshot.groups
            self.binItems = snapshot.bin
            self.isLoading = false
        }
    }

    struct Snapshot: Sendable {
        let groups: [LibraryGroup]
        let bin: [LibraryItem]
    }

    // nonisolated so it can run off the main actor. Everything it touches is
    // either passed in or read fresh from the filesystem.
    nonisolated private static func scan(sortOrder: LibrarySortOrder,
                                         overrides: [String: LibrarySortOrder],
                                         retentionMonths: Int) -> Snapshot {
        purgeBin(retentionMonths: retentionMonths)
        let root = FlashbackStorage.localFolder
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles]) else {
            return Snapshot(groups: [], bin: loadBin())
        }

        var rootFiles: [URL] = []
        var subdirs: [URL] = []
        for e in entries {
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir == true { subdirs.append(e) } else { rootFiles.append(e) }
        }

        var result: [LibraryGroup] = []

        let ungrouped = buildItems(from: rootFiles, groupPrefix: "",
                                   sortOrder: overrides[ungroupedID] ?? sortOrder)
        if !ungrouped.isEmpty {
            result.append(LibraryGroup(id: ungroupedID, name: "Ungrouped",
                                       isUngrouped: true, folderURL: root, items: ungrouped))
        }

        for dir in subdirs.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let name = dir.lastPathComponent
            let items = buildItems(from: files, groupPrefix: name,
                                   sortOrder: overrides[name] ?? sortOrder)
            result.append(LibraryGroup(id: name, name: name,
                                       isUngrouped: false, folderURL: dir, items: items))
        }

        return Snapshot(groups: result, bin: loadBin())
    }

    nonisolated private static func buildItems(from urls: [URL], groupPrefix: String,
                                               sortOrder: LibrarySortOrder) -> [LibraryItem] {
        struct Acc { var dng: URL?; var jpg: URL?; var date: Date; var size: Int }
        var acc: [String: Acc] = [:]
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard Self.imageExts.contains(ext) else { continue }
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
            let captureURL = g.dng ?? g.jpg
            // Cached by path+mtime+size, so each file's EXIF header is only ever
            // read once instead of on every single library refresh.
            let captured = captureURL.flatMap { CaptureDateCache.shared.date(for: $0, mtime: g.date, size: g.size) }
            return LibraryItem(id: groupPrefix.isEmpty ? base : "\(groupPrefix)/\(base)",
                        displayName: (g.dng ?? g.jpg)?.lastPathComponent ?? base,
                        dngURL: g.dng, jpegURL: g.jpg, date: g.date, captureDate: captured, sizeBytes: g.size)
        }
        .sorted(by: sortOrder.areInOrder)
    }

    // MARK: Mutations

    // Deleting moves files to the recycle bin (auto-purged after the retention
    // period set in Settings), so they can be recovered.
    func delete(_ item: LibraryItem) {
        moveToBin(items: [item])
        load()
    }

    func delete(ids: Set<String>) {
        moveToBin(items: allItems.filter { ids.contains($0.id) })
        load()
    }

    /// Delete a group. Default = ungroup (move its photos to the root). If
    /// `deletePhotos` is set, the photos go to the recycle bin instead.
    func deleteGroup(_ group: LibraryGroup, deletePhotos: Bool) {
        guard !group.isUngrouped else { return }
        if deletePhotos {
            moveToBin(items: group.items)
        } else {
            let root = FlashbackStorage.localFolder
            for item in group.items {
                moveFiles([item.dngURL, item.jpegURL].compactMap { $0 }, into: root)
                ThumbnailCache.shared.remove(item.id)
            }
        }
        try? FileManager.default.removeItem(at: group.folderURL)
        load()
    }

    /// Move items back to the root (Ungrouped) — not a folder literally named
    /// "Ungrouped", just files at the top level.
    func moveToUngrouped(ids: Set<String>) {
        let root = FlashbackStorage.localFolder
        for item in allItems where ids.contains(item.id) {
            moveFiles([item.dngURL, item.jpegURL].compactMap { $0 }, into: root)
            ThumbnailCache.shared.remove(item.id)
        }
        load()
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
        // Spaces become hyphens ("Summer Roll 3" → "Summer-Roll-3") so folder
        // names stay clean in the Files app; / and : are illegal in file names.
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        // A leading dot would make the folder hidden — the Library skips hidden
        // entries, so the group would silently vanish along with its photos.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        guard !cleaned.isEmpty else { return nil }
        // "Ungrouped" is the display name of the virtual root group. A real
        // folder by that name would render as a second, confusingly identical
        // section that behaves differently for move/rename.
        if cleaned.compare("Ungrouped", options: .caseInsensitive) == .orderedSame {
            cleaned = "Ungrouped-1"
        }
        return cleaned
    }

    func fileURLs(for ids: Set<String>) -> [URL] {
        (allItems + binItems).filter { ids.contains($0.id) }
            .flatMap { [$0.dngURL, $0.jpegURL].compactMap { $0 } }
    }

    var showsRawBadges: Bool {
        allItems.contains { $0.dngURL == nil } && allItems.contains { $0.dngURL != nil }
    }

    // MARK: Recycle bin

    // Bin filenames are "<epoch>##<group>##<originalName>" so we can restore to
    // the right folder and purge by age.
    private func moveToBin(items: [LibraryItem]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: binURL, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        for item in items {
            for url in [item.dngURL, item.jpegURL].compactMap({ $0 }) {
                let group = groupName(forFileAt: url)
                let name = "\(stamp)\(binDelimiter)\(group)\(binDelimiter)\(url.lastPathComponent)"
                let dest = binURL.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try? fm.moveItem(at: url, to: dest)
            }
            ThumbnailCache.shared.remove(item.id)
        }
    }

    private func groupName(forFileAt url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        return parent.path == FlashbackStorage.localFolder.path ? "" : parent.lastPathComponent
    }

    nonisolated private static func loadBin() -> [LibraryItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: binURL, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        struct Acc { var dng: URL?; var jpg: URL?; var size: Int; var date: Date; var origName: String }
        var acc: [String: Acc] = [:]
        for url in files {
            let ext = url.pathExtension.lowercased()
            guard Self.imageExts.contains(ext) else { continue }
            let parts = url.lastPathComponent.components(separatedBy: binDelimiter)
            guard parts.count >= 3, let ms = Double(parts[0]) else { continue }
            let group = parts[1]
            let orig = parts[2...].joined(separator: binDelimiter)
            let base = (orig as NSString).deletingPathExtension
            let key = "\(parts[0])\(binDelimiter)\(group)\(binDelimiter)\(base)"
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var a = acc[key] ?? Acc(dng: nil, jpg: nil, size: 0, date: Date(timeIntervalSince1970: ms), origName: orig)
            if ext == "dng" { a.dng = url; a.origName = orig } else { a.jpg = url }
            a.size += size
            acc[key] = a
        }
        return acc.map { key, a in
            LibraryItem(id: "bin/\(key)", displayName: a.origName,
                        dngURL: a.dng, jpegURL: a.jpg, date: a.date, captureDate: nil, sizeBytes: a.size)
        }
        .sorted { $0.date > $1.date }   // deletion time, not capture time
    }

    nonisolated private static func purgeBin(retentionMonths: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: binURL, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionMonths) * 30 * 24 * 3600)
        for url in files {
            let parts = url.lastPathComponent.components(separatedBy: binDelimiter)
            if let s = parts.first, let ms = Double(s), Date(timeIntervalSince1970: ms) < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    func restore(ids: Set<String>) {
        let root = FlashbackStorage.localFolder
        let fm = FileManager.default
        for item in binItems where ids.contains(item.id) {
            for url in [item.dngURL, item.jpegURL].compactMap({ $0 }) {
                let parts = url.lastPathComponent.components(separatedBy: binDelimiter)
                guard parts.count >= 3 else { continue }
                let group = parts[1]
                let orig = parts[2...].joined(separator: binDelimiter)
                let folder = group.isEmpty ? root : root.appendingPathComponent(group, isDirectory: true)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let dest = folder.appendingPathComponent(orig)
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try? fm.moveItem(at: url, to: dest)
            }
            ThumbnailCache.shared.remove(item.id)
        }
        load()
    }

    func deleteFromBin(ids: Set<String>) {
        for item in binItems where ids.contains(item.id) {
            for url in [item.dngURL, item.jpegURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
            ThumbnailCache.shared.remove(item.id)
        }
        load()
    }

    func emptyBin() {
        try? FileManager.default.removeItem(at: binURL)
        load()
    }
}

// MARK: - Capture date cache

// EXIF reads are cheap individually but add up across a whole library, and the
// answer never changes for a given file. Keyed by path+mtime+size so an edited
// or replaced file is re-read automatically. Thread-safe: the library scan runs
// off the main actor.
final class CaptureDateCache: @unchecked Sendable {
    static let shared = CaptureDateCache()
    private var entries: [String: Date?] = [:]
    private let lock = NSLock()
    private let defaultsKey = "captureDateCache"

    init() {
        if let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] {
            for (k, v) in raw { entries[k] = v == 0 ? Date?.none : Date(timeIntervalSince1970: v) }
        }
    }

    func date(for url: URL, mtime: Date, size: Int) -> Date? {
        let key = "\(url.path)|\(Int(mtime.timeIntervalSince1970))|\(size)"
        lock.lock()
        if let hit = entries[key] { lock.unlock(); return hit }
        lock.unlock()

        let value = EXIFDateReader.captureDate(for: url)

        lock.lock()
        entries[key] = value
        // Keep the persisted map from growing without bound across many rolls.
        if entries.count > 5000 { entries.removeAll() }
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
        return value
    }

    private func persist(_ snapshot: [String: Date?]) {
        // 0 encodes "no EXIF date" so negative results are cached too.
        let encoded = snapshot.mapValues { $0?.timeIntervalSince1970 ?? 0 }
        UserDefaults.standard.set(encoded, forKey: defaultsKey)
    }
}

// MARK: - Thumbnail cache + decoding

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private let dir: URL
    // Rendered thumbnails are ~20-60KB each; without a cap the on-disk cache
    // grew forever as photos came and went.
    private let maxDiskBytes = 200 * 1024 * 1024
    private var writesSinceSweep = 0

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlashbackThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func image(for key: String) -> UIImage? {
        if let mem = cache.object(forKey: key as NSString) { return mem }
        // Fall back to the on-disk render so re-launching the Library is instant.
        let url = fileURL(key)
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            cache.setObject(img, forKey: key as NSString)
            // Touch for LRU so frequently-viewed thumbs survive eviction.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return img
        }
        return nil
    }

    func set(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: fileURL(key))
        }
        writesSinceSweep += 1
        if writesSinceSweep >= 50 {
            writesSinceSweep = 0
            let dir = self.dir, cap = self.maxDiskBytes
            Task.detached(priority: .background) { Self.sweep(dir: dir, maxBytes: cap) }
        }
    }

    func remove(_ key: String) {
        cache.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: fileURL(key))
    }

    private func fileURL(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    /// Evict least-recently-used thumbnails until the folder is under the cap.
    nonisolated private static func sweep(dir: URL, maxBytes: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for f in files {
            guard let rv = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            let size = rv.fileSize ?? 0
            entries.append((f, size, rv.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > maxBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {   // oldest first
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            if total <= maxBytes { break }
        }
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
