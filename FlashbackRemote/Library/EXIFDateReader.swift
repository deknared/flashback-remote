import Foundation
import ImageIO

// Reads the shot date from a DNG/JPEG so the Library can sort by when the photo
// was actually taken, not when it was transferred to the phone.
enum EXIFDateReader {
    private static let exifFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func captureDate(for url: URL) -> Date? {
        switch url.pathExtension.lowercased() {
        case "dng": return dngDate(url)
        case "jpg", "jpeg": return jpegDate(url)
        default: return nil
        }
    }

    // Fast path: ImageIO reads embedded EXIF without decoding pixels.
    private static func jpegDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifFormat.date(from: raw)
    }

    // DNG is TIFF: scan IFD0 for DateTimeOriginal (0x9003, sometimes here) or the
    // Exif sub-IFD pointer (0x8769) → DateTimeOriginal there. Only reads the first
    // 8KB — the ONE35's tags sit well before the pixel strip (offset 2048+), so a
    // partial read is enough and avoids loading the full ~16MB file per photo.
    private static func dngDate(_ url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192), data.count >= 16 else { return nil }

        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Date? in
            guard let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            func u16(_ o: Int, _ le: Bool) -> Int? {
                guard o + 2 <= buf.count else { return nil }
                return le ? Int(p[o]) | (Int(p[o+1]) << 8) : (Int(p[o]) << 8) | Int(p[o+1])
            }
            func u32(_ o: Int, _ le: Bool) -> Int? {
                guard o + 4 <= buf.count else { return nil }
                return le ? Int(p[o]) | (Int(p[o+1])<<8) | (Int(p[o+2])<<16) | (Int(p[o+3])<<24)
                          : (Int(p[o])<<24) | (Int(p[o+1])<<16) | (Int(p[o+2])<<8) | Int(p[o+3])
            }
            func ascii(_ entryOffset: Int, _ le: Bool) -> String? {
                guard let count = u32(entryOffset + 4, le) else { return nil }
                let valueOffset = count <= 4 ? entryOffset + 8 : (u32(entryOffset + 8, le) ?? -1)
                guard valueOffset >= 0, valueOffset + count <= buf.count, count > 0 else { return nil }
                var s = ""
                for k in 0..<(count - 1) { s.append(Character(UnicodeScalar(p[valueOffset + k]))) }
                return s
            }
            func scan(_ ifd: Int, _ le: Bool, want: [Int]) -> [Int: Int] {
                var found: [Int: Int] = [:]
                guard ifd > 0, let n = u16(ifd, le) else { return found }
                for i in 0..<n {
                    let e = ifd + 2 + i * 12
                    guard e + 12 <= buf.count, let tag = u16(e, le) else { break }
                    if want.contains(tag) { found[tag] = e }
                }
                return found
            }

            guard let order = u16(0, false) else { return nil }
            let le = order == 0x4949
            guard let ifd0Offset = u32(4, le) else { return nil }
            let ifd0 = scan(ifd0Offset, le, want: [0x8769, 0x9003, 0x0132])

            if let e = ifd0[0x9003], let s = ascii(e, le), let d = exifFormat.date(from: s) { return d }
            if let exifPtr = ifd0[0x8769], let exifIfd = u32(exifPtr + 8, le) {
                let exif = scan(exifIfd, le, want: [0x9003])
                if let e = exif[0x9003], let s = ascii(e, le), let d = exifFormat.date(from: s) { return d }
            }
            if let e = ifd0[0x0132], let s = ascii(e, le), let d = exifFormat.date(from: s) { return d }
            return nil
        }
    }
}
