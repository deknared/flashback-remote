import UIKit
import CoreGraphics

// Pure-Swift decoder for Flashback ONE35 DNGs, ported from the editor's
// one35-dng.js + config.js. The ONE35 stores uncompressed 10-bit MSB-packed
// RGGB Bayer (4144×3088, black 64, white 1023, strip at offset 2048) — a layout
// iOS's CIRAWFilter mis-reads (the red/yellow banding). This reads the mosaic
// directly and applies the editor's neutral colour transform (÷ASN_D50 → FM1 →
// D50→D60 → ACEScg → linear sRGB), then a gentle highlight roll-off + sRGB gamma.
// Neutral preview only — no film looks / tone curve.
enum One35DNGDecoder {
    private static let sensorW = 4144
    private static let sensorH = 3088
    private static let black: Double = 64
    private static let scale: Double = 1.0 / (1023 - 64)   // 1/959
    private static let bytesPerRow = (4144 * 10) / 8        // 5180
    private static let lift: Double = 4.0                   // ~2 EV
    private static let matrix: [Double] = computeMatrix()   // raw → linear sRGB

    static func decode(url: URL, maxDimension: Int) -> UIImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return decode(data: data, maxDimension: maxDimension)
    }

    static func decode(data: Data, maxDimension: Int) -> UIImage? {
        let stripOffset = readStripOffset(data)
        guard data.count >= stripOffset + bytesPerRow * sensorH else { return nil }

        let halfW = sensorW / 2   // 2072
        let halfH = sensorH / 2   // 1544
        let step = max(1, Int((Double(max(halfW, halfH)) / Double(max(maxDimension, 1))).rounded()))
        let outW = halfW / step
        let outH = halfH / step
        guard outW > 0, outH > 0 else { return nil }

        var rgba = [UInt8](repeating: 255, count: outW * outH * 4)
        let m = matrix

        data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let raw0 = rawBuf.baseAddress else { return }
            let base = raw0.advanced(by: stripOffset).assumingMemoryBound(to: UInt8.self)
            for ty in 0..<outH {
                let sy = (ty * step) * 2                    // even sensor row of the 2×2 block
                let evenStart = sy * bytesPerRow
                let oddStart = (sy + 1) * bytesPerRow
                for tx in 0..<outW {
                    let sx = (tx * step) * 2                // R site
                    let r  = pixel(base, evenStart, sx)
                    let g1 = pixel(base, evenStart, sx + 1)
                    let g2 = pixel(base, oddStart, sx)
                    let b  = pixel(base, oddStart, sx + 1)
                    let rr = (Double(r)  - black) * scale
                    let gg = ((Double(g1) - black) + (Double(g2) - black)) * 0.5 * scale
                    let bb = (Double(b)  - black) * scale
                    let lr = tone(m[0]*rr + m[1]*gg + m[2]*bb)
                    let lg = tone(m[3]*rr + m[4]*gg + m[5]*bb)
                    let lb = tone(m[6]*rr + m[7]*gg + m[8]*bb)
                    let di = (ty * outW + tx) * 4
                    rgba[di]     = encode(lr)
                    rgba[di + 1] = encode(lg)
                    rgba[di + 2] = encode(lb)
                }
            }
        }

        return makeImage(rgba, width: outW, height: outH)
    }

    // MARK: - Per-pixel helpers

    @inline(__always)
    private static func pixel(_ base: UnsafePointer<UInt8>, _ rowStart: Int, _ p: Int) -> Int {
        // 10-bit MSB packing: 4 pixels per 5 bytes.
        let b = rowStart + (p >> 2) * 5
        switch p & 3 {
        case 0:  return (Int(base[b]) << 2) | (Int(base[b + 1]) >> 6)
        case 1:  return ((Int(base[b + 1]) & 0x3F) << 4) | (Int(base[b + 2]) >> 4)
        case 2:  return ((Int(base[b + 2]) & 0x0F) << 6) | (Int(base[b + 3]) >> 2)
        default: return ((Int(base[b + 3]) & 0x03) << 8) | Int(base[b + 4])
        }
    }

    @inline(__always)
    private static func tone(_ x: Double) -> Double {
        let v = (x < 0 ? 0 : x) * lift
        return v / (1 + v)   // Reinhard highlight roll-off
    }

    @inline(__always)
    private static func encode(_ v: Double) -> UInt8 {
        let c = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8((max(0, min(1, c)) * 255).rounded())
    }

    private static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        var pixels = rgba
        return pixels.withUnsafeMutableBytes { ptr -> UIImage? in
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: ptr.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }
    }

    // MARK: - TIFF strip offset

    private static func readStripOffset(_ data: Data) -> Int {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            guard buf.count >= 16, let p = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 2048 }
            func u16(_ o: Int, _ le: Bool) -> Int {
                le ? Int(p[o]) | (Int(p[o + 1]) << 8) : (Int(p[o]) << 8) | Int(p[o + 1])
            }
            func u32(_ o: Int, _ le: Bool) -> Int {
                le ? Int(p[o]) | (Int(p[o + 1]) << 8) | (Int(p[o + 2]) << 16) | (Int(p[o + 3]) << 24)
                   : (Int(p[o]) << 24) | (Int(p[o + 1]) << 16) | (Int(p[o + 2]) << 8) | Int(p[o + 3])
            }
            let le = (Int(p[0]) | (Int(p[1]) << 8)) == 0x4949
            let ifd0 = u32(4, le)
            guard ifd0 + 2 <= buf.count else { return 2048 }
            let n = u16(ifd0, le)
            for i in 0..<n {
                let e = ifd0 + 2 + i * 12
                guard e + 12 <= buf.count else { break }
                if u16(e, le) != 0x0111 { continue }   // StripOffsets
                let type = u16(e + 2, le)
                let count = u32(e + 4, le)
                if count == 1 {
                    return type == 3 ? u16(e + 8, le) : u32(e + 8, le)
                }
                let off = u32(e + 8, le)
                guard off + 4 <= buf.count else { return 2048 }
                return type == 3 ? u16(off, le) : u32(off, le)
            }
            return 2048
        }
    }

    // MARK: - Colour matrix (raw → linear sRGB), from the editor's config.js

    private static func computeMatrix() -> [Double] {
        let asn: [Double] = [0.541, 1.0, 0.597]
        let fm1: [Double] = [
            0.53086,  0.22116,  0.21219,
            0.08570,  0.98930, -0.07500,
            0.04526, -0.37228,  1.15192
        ]
        let bradford: [Double] = [
             0.98722400, -0.00611327, 0.01595330,
            -0.00759836,  1.00186000, 0.00533002,
             0.00307257, -0.00509595, 1.08168000
        ]
        let xyzD60ToAces: [Double] = [
             1.6410233797, -0.3248032942, -0.2364246952,
            -0.6636628587,  1.6153315917,  0.0167563477,
             0.0117218943, -0.0082844420,  0.9883948585
        ]
        let acesToLinSRGB: [Double] = [
             1.70505, -0.62179, -0.08326,
            -0.13026,  1.14080, -0.01055,
            -0.02400, -0.12897,  1.15297
        ]
        var fmOverAsn = fm1
        for i in 0..<9 { fmOverAsn[i] = fm1[i] / asn[i % 3] }   // fold in ÷ASN white balance
        let rawToAces = mul(xyzD60ToAces, mul(bradford, fmOverAsn))
        return mul(acesToLinSRGB, rawToAces)
    }

    private static func mul(_ a: [Double], _ b: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                o[r * 3 + c] = a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c]
            }
        }
        return o
    }
}
