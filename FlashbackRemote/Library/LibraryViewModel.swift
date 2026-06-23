import Foundation
import UIKit
import ImageIO
import CoreImage

// One entry in the Library — a captured frame, which may have a DNG, a JPEG, or
// both (same basename). Deleting an item removes every file for that basename.
struct LibraryItem: Identifiable, Hashable {
    let id: String          // basename without extension
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

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [LibraryItem] = []
    @Published var isLoading = false

    func load() {
        isLoading = true
        let folder = FlashbackStorage.localFolder
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder,
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else {
            items = []
            isLoading = false
            return
        }

        struct Group { var dng: URL?; var jpg: URL?; var date: Date; var size: Int }
        var groups: [String: Group] = [:]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "dng" || ext == "jpg" || ext == "jpeg" else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            let rv = try? url.resourceValues(forKeys: Set(keys))
            let date = rv?.contentModificationDate ?? .distantPast
            let size = rv?.fileSize ?? 0
            var g = groups[base] ?? Group(dng: nil, jpg: nil, date: .distantPast, size: 0)
            if ext == "dng" { g.dng = url } else { g.jpg = url }
            g.size += size
            if date > g.date { g.date = date }
            groups[base] = g
        }

        items = groups.map { base, g in
            LibraryItem(id: base,
                        displayName: (g.dng ?? g.jpg)?.lastPathComponent ?? base,
                        dngURL: g.dng,
                        jpegURL: g.jpg,
                        date: g.date,
                        sizeBytes: g.size)
        }
        .sorted { $0.date > $1.date }
        isLoading = false
    }

    // Delete removes the DNG and any matching JPEG for this frame.
    func delete(_ item: LibraryItem) {
        for url in [item.dngURL, item.jpegURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
        ThumbnailCache.shared.remove(item.id)
    }

    func delete(ids: Set<String>) {
        for item in items where ids.contains(item.id) {
            for url in [item.dngURL, item.jpegURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
            ThumbnailCache.shared.remove(item.id)
        }
        items.removeAll { ids.contains($0.id) }
    }

    // All files (DNG + JPEG) for the given items, for the share sheet.
    func fileURLs(for ids: Set<String>) -> [URL] {
        items.filter { ids.contains($0.id) }
            .flatMap { [$0.dngURL, $0.jpegURL].compactMap { $0 } }
    }

    // True when the library holds a mix of raw and non-raw frames, so a RAW badge
    // is meaningful. If everything is a DNG, the badge is just noise.
    var showsRawBadges: Bool {
        items.contains { $0.dngURL == nil } && items.contains { $0.dngURL != nil }
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
