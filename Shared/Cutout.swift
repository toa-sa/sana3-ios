//
//  Cutout.swift
//  Image Cleaner — TOA
//
//  Background removal with clean edges.
//
//  1. Plain backgrounds (logos, icons, product shots on white…): the background colour is
//     measured on the image border and removed by a flood fill from the edges, so only
//     background that touches the border goes — white inside the subject stays.
//  2. Photos: Apple Vision's subject mask.
//  In both cases the edge pixels are "decontaminated": the background colour mixed into
//  them is subtracted, so there is no white/grey halo on dark backgrounds.
//

import Foundation
import CoreGraphics
import CoreImage

struct RGBAImage {
    var pixels: [UInt8]            // RGBA, straight (not premultiplied)
    let width: Int
    let height: Int
    var space: CGColorSpace

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        space = ImageTools.rgbSpace(of: image)
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // Some wide / HDR colour spaces can't back an 8-bit context: fall back to sRGB instead of crashing.
        var ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: info)
        if ctx == nil {
            space = srgb
            ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: srgb, bitmapInfo: info)
        }
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // un-premultiply (opaque images are unchanged)
        for i in stride(from: 0, to: buf.count, by: 4) where buf[i + 3] != 255 && buf[i + 3] != 0 {
            let a = Double(buf[i + 3]) / 255
            for c in 0..<3 { buf[i + c] = UInt8(min(255, (Double(buf[i + c]) / a).rounded())) }
        }
        pixels = buf
    }

    /// Straight RGBA + alpha -> premultiplied CGImage. Reuses the pixel buffer (no second full-size copy).
    mutating func makeImage(alpha: [Float]) -> CGImage? {
        for p in 0..<(width * height) {
            let a = max(0, min(1, alpha[p]))
            let i = p * 4
            pixels[i] = UInt8((Float(pixels[i]) * a).rounded())
            pixels[i + 1] = UInt8((Float(pixels[i + 1]) * a).rounded())
            pixels[i + 2] = UInt8((Float(pixels[i + 2]) * a).rounded())
            pixels[i + 3] = UInt8((a * 255).rounded())
        }
        let data = Data(pixels)
        pixels = []
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A plain background found on the image border.
struct PlainBackground {
    let color: (Float, Float, Float)
    let tolerance: Float          // distance below which a pixel is pure background
}

enum Cutout {

    // MARK: Plain background

    /// Looks at a ring around the border; plain when most of it is one colour.
    /// An image whose border is already mostly transparent (a cut-out logo, an SVG drawing) has
    /// no background left to find: its own alpha is the answer. Without this the opaque pixels
    /// that touch the border (e.g. a letter at the edge) were taken for the background colour
    /// and removed.
    static func existingAlpha(_ img: RGBAImage) -> [Float]? {
        let w = img.width, h = img.height
        guard w >= 4, h >= 4 else { return nil }
        var clear = 0, total = 0
        func check(_ x: Int, _ y: Int) {
            total += 1
            if img.pixels[(y * w + x) * 4 + 3] < 10 { clear += 1 }
        }
        for x in 0..<w { check(x, 0); check(x, h - 1) }
        for y in 1..<(h - 1) { check(0, y); check(w - 1, y) }
        guard Float(clear) >= Float(total) * 0.25 else { return nil }
        var alpha = [Float](repeating: 0, count: w * h)
        for p in 0..<(w * h) { alpha[p] = Float(img.pixels[p * 4 + 3]) / 255 }
        return alpha
    }

    static func detectPlain(_ img: RGBAImage) -> PlainBackground? {
        let w = img.width, h = img.height
        guard w >= 16, h >= 16 else { return nil }
        let ring = max(2, min(w, h) / 100)
        var samples: [(Float, Float, Float)] = []
        let step = max(1, (2 * (w + h) * ring) / 6000)
        var k = 0
        for y in 0..<h {
            let edgeRow = y < ring || y >= h - ring
            var x = 0
            while x < w {
                if edgeRow || x < ring || x >= w - ring {
                    if k % step == 0 {
                        let i = (y * w + x) * 4
                        if img.pixels[i + 3] > 200 {
                            samples.append((Float(img.pixels[i]), Float(img.pixels[i + 1]), Float(img.pixels[i + 2])))
                        }
                    }
                    k += 1
                    x += 1
                } else {
                    x = w - ring             // jump to the right border
                }
            }
        }
        guard samples.count > 40 else { return nil }
        func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
        let bg = (median(samples.map(\.0)), median(samples.map(\.1)), median(samples.map(\.2)))
        let dists = samples.map { dist($0, bg) }.sorted()
        let close = dists.filter { $0 < 28 }.count
        guard Float(close) / Float(dists.count) >= 0.88 else { return nil }
        // Tolerance from the border's own noise (JPEG artefacts, gradients), within sane limits.
        let p90 = dists[min(dists.count - 1, dists.count * 9 / 10)]
        return PlainBackground(color: bg, tolerance: min(26, max(8, p90 * 1.6 + 4)))
    }

    /// Alpha for a plain background: flood fill from the border through background-coloured
    /// pixels, then soft alpha on the 2-pixel band where background meets subject.
    static func plainAlpha(_ img: RGBAImage, _ bg: PlainBackground, everywhere: Bool = false) -> [Float] {
        // Memory-lean on purpose (48 MP photos): no per-pixel distance table, 1-byte flags, 32-bit queue.
        let w = img.width, h = img.height, n = w * h
        let tLo = bg.tolerance, tHi = bg.tolerance + 70
        let B = bg.color
        func distance(_ p: Int) -> Float {
            let i = p * 4
            if img.pixels[i + 3] < 10 { return 0 }
            return dist((Float(img.pixels[i]), Float(img.pixels[i + 1]), Float(img.pixels[i + 2])), B)
        }

        // 0 = subject, 1 = background, 2...7 = steps from the background (edge band)
        var state = [UInt8](repeating: 0, count: n)
        var queue = [Int32](); queue.reserveCapacity(min(n, 1 << 20))
        func seed(_ p: Int) { if state[p] == 0 && distance(p) < tLo { state[p] = 1; queue.append(Int32(p)) } }
        if everywhere {
            for p in 0..<n { seed(p) }                 // every pixel of the background colour
        } else {
            for x in 0..<w { seed(x); seed((h - 1) * w + x) }
            for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        }
        var head = 0
        while head < queue.count {
            let p = Int(queue[head]); head += 1
            let x = p % w, y = p / w
            if x > 0 { seed(p - 1) }
            if x < w - 1 { seed(p + 1) }
            if y > 0 { seed(p - w) }
            if y < h - 1 { seed(p + w) }
            if head > 1 << 20 && head * 2 > queue.count {                // keep the queue small
                queue.removeFirst(head); head = 0
            }
        }
        queue = []

        // Edge band: the first 3 pixels of the subject next to the background. Their colour is a mix
        // of the background and the subject's own colour just inside. Estimate how much of each:
        //   alpha = (C - B)·(F - B) / |F - B|²   with F = subject colour a few px inside.
        let bandWidth = 3
        var frontier = [Int32]()
        for p in 0..<n where state[p] == 1 {
            let x = p % w, y = p / w
            for q in [x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1]
            where q >= 0 && state[q] == 0 {
                state[q] = 2; frontier.append(Int32(q))
            }
        }
        var band = frontier
        var depth: UInt8 = 2
        while depth < UInt8(bandWidth + 4) && !frontier.isEmpty {
            var next = [Int32]()
            for p32 in frontier {
                let p = Int(p32), x = p % w, y = p / w
                for q in [x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1]
                where q >= 0 && state[q] == 0 {
                    state[q] = depth + 1; next.append(Int32(q))
                }
            }
            if depth < UInt8(bandWidth + 1) { band += next }
            frontier = next
            depth += 1
        }
        frontier = []

        var alpha = [Float](repeating: 1, count: n)
        for p in 0..<n where state[p] == 1 { alpha[p] = 0 }
        let inner = UInt8(bandWidth + 1)                              // states > inner (or 0) = solid subject
        for p32 in band {
            let p = Int(p32), x = p % w, y = p / w
            var fr: Float = 0, fg: Float = 0, fb: Float = 0, c: Float = 0
            for dy in -4...4 { for dx in -4...4 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                let q = yy * w + xx
                guard state[q] == 0 || state[q] > inner else { continue }
                let i = q * 4
                fr += Float(img.pixels[i]); fg += Float(img.pixels[i + 1]); fb += Float(img.pixels[i + 2]); c += 1
            } }
            let i = p * 4
            let C = (Float(img.pixels[i]), Float(img.pixels[i + 1]), Float(img.pixels[i + 2]))
            if c > 0 {
                let F = (fr / c, fg / c, fb / c)
                let fx = F.0 - B.0, fy = F.1 - B.1, fz = F.2 - B.2
                let len2 = fx * fx + fy * fy + fz * fz
                if len2 > 400 {                                      // subject clearly differs from the background
                    let t = ((C.0 - B.0) * fx + (C.1 - B.1) * fy + (C.2 - B.2) * fz) / len2
                    alpha[p] = max(0, min(1, t))
                    continue
                }
            }
            alpha[p] = max(0, min(1, (distance(p) - tLo) / (tHi - tLo)))    // fallback: distance from the background
        }
        return alpha
    }

    // MARK: Vision mask

    /// Full-resolution soft mask from Vision, tightened so the soft halo does not keep background.
    static func visionAlpha(_ mask: CIImage, width: Int, height: Int) -> [Float]? {
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var buf = [Float](repeating: 0, count: width * height)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        ctx.render(mask.cropped(to: extent), toBitmap: &buf, rowBytes: width * 4, bounds: extent,
                   format: .Lf, colorSpace: nil)
        // CoreImage renders bottom-up; flip rows.
        var flipped = [Float](repeating: 0, count: buf.count)
        for y in 0..<height {
            let src = (height - 1 - y) * width
            flipped.replaceSubrange((y * width)..<(y * width + width), with: buf[src..<(src + width)])
        }
        // Remap: <0.12 -> 0, >0.88 -> 1, smooth in between (removes the faint glow).
        return flipped.map { v in
            let t = max(0, min(1, (v - 0.12) / 0.76))
            return t * t * (3 - 2 * t)
        }
    }

    // MARK: Edge clean-up

    /// Removes the background colour mixed into semi-transparent edge pixels.
    /// Plain backgrounds use the known colour; photos use the average of clearly-background pixels
    /// sampled around each edge pixel (only edge pixels are visited, so memory stays flat).
    static func decontaminate(_ img: inout RGBAImage, alpha: [Float], plain: PlainBackground?) {
        let w = img.width, h = img.height
        let r = max(3, min(w, h) / 120)
        let step = max(1, r / 4)
        for p in 0..<(w * h) {
            let a = alpha[p]
            guard a > 0.01, a < 0.99 else { continue }
            var b: (Float, Float, Float)
            if let plain {
                b = plain.color
            } else {
                let x = p % w, y = p / w
                var sr: Float = 0, sg: Float = 0, sb: Float = 0, c: Float = 0
                var dy = -r
                while dy <= r {
                    var dx = -r
                    while dx <= r {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0, yy >= 0, xx < w, yy < h {
                            let q = yy * w + xx
                            if alpha[q] < 0.05 {
                                let i = q * 4
                                sr += Float(img.pixels[i]); sg += Float(img.pixels[i + 1]); sb += Float(img.pixels[i + 2]); c += 1
                            }
                        }
                        dx += step
                    }
                    dy += step
                }
                guard c > 0 else { continue }                       // no background nearby: leave as is
                b = (sr / c, sg / c, sb / c)
            }
            let i = p * 4
            for (ch, bc) in [(0, b.0), (1, b.1), (2, b.2)] {
                let v = (Float(img.pixels[i + ch]) - (1 - a) * bc) / a
                img.pixels[i + ch] = UInt8(max(0, min(255, v.rounded())))
            }
        }
    }

    /// Bounding box of the opaque part, in pixels.
    static func subjectBox(alpha: [Float], width w: Int, height h: Int) -> CGRect? {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where alpha[y * w + x] > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Optional extra softness (slider), as a small blur of the alpha only.
    static func soften(_ alpha: [Float], width w: Int, height h: Int, amount: Double) -> [Float] {
        let r = Int((amount * Double(min(w, h)) * 0.004).rounded())
        guard r >= 1 else { return alpha }
        var tmp = alpha, out = alpha
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0, c: Float = 0
                for k in max(0, x - r)...min(w - 1, x + r) { s += alpha[y * w + k]; c += 1 }
                tmp[y * w + x] = s / c
            }
        }
        for x in 0..<w {
            for y in 0..<h {
                var s: Float = 0, c: Float = 0
                for k in max(0, y - r)...min(h - 1, y + r) { s += tmp[k * w + x]; c += 1 }
                out[y * w + x] = min(alpha[y * w + x], s / c)        // only soften outwards edges, never add background
            }
        }
        return out
    }

    private static func dist(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
