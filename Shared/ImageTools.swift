//
//  ImageTools.swift
//  Image Cleaner — TOA
//
//  Optional tools applied AFTER cleaning: background removal, smart resize,
//  format change. These re-encode the image (new pixels), so every result is
//  cleaned again by CleanerCore before it is used.
//

import Foundation
import ImageIO
import CoreGraphics
import CoreImage
import Accelerate
import Vision
import UniformTypeIdentifiers

enum OutputFormat: String, CaseIterable, Identifiable {
    case jpeg, png, heic, svg

    var id: String { rawValue }
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    var title: String { self == .jpeg ? "JPG" : rawValue.uppercased() }
    var isLossy: Bool { self == .jpeg || self == .heic }
    var supportsTransparency: Bool { self != .jpeg }
    var typeIdentifier: String {
        switch self {
        case .jpeg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return UTType.heic.identifier
        case .svg: return UTType.svg.identifier
        }
    }

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        case "heic", "heif": self = .heic
        case "svg": self = .svg
        default: return nil
        }
    }
}

enum SizeTarget: Equatable {
    case pixels(Int, Int)
    case scale(Double)
}

enum ResizeMode: Equatable {
    case smartCrop      // fill the exact size, crop around the important part
    case fit            // keep the whole picture, fit inside the size
}

enum BackgroundFill {
    case transparent
    case color(CGColor)
    case blur(Double)           // 0...1
}

struct EditOptions {
    // Format
    var format: OutputFormat? = nil          // nil = keep the current format
    var quality: Double = 0.9
    // Size
    var size: SizeTarget? = nil
    var resizeMode: ResizeMode = .smartCrop
    var focus: CGPoint? = nil                // normalized, top-left origin; nil = automatic
    var crop: CGRect? = nil                  // normalized crop chosen by the user (zoom + move); wins over focus
    // Background
    var removeBackground = false
    var background: BackgroundFill = .transparent
    var excludedPoints: [CGPoint] = []       // normalized; subjects under these points are removed
    var edgeSoftness: Double = 0             // 0...1
    var cropToSubject = false
    var removeEnclosedBackground = false     // plain backgrounds: also remove enclosed areas of that colour
    var subjectMargin: Double = 0.08         // fraction of the subject size

    var isEmpty: Bool { format == nil && size == nil && !removeBackground }
}

struct EditResult {
    let data: Data
    let fileExtension: String
    let note: String
    let warnings: [String]
}

struct Processed {
    let image: CGImage
    let transparent: Bool
    let notes: [String]
    let warnings: [String]
}

// MARK: - Subjects (Vision)

/// People / objects found in one image. Computed once and reused while the user adjusts options.
/// iOS 17+: every person / animal / object separately (Vision subject lifting).
/// iOS 15–16: people only, as one subject (Vision person segmentation).
final class SubjectAnalysis: @unchecked Sendable {
    let width: Int
    let height: Int
    let allInstances: IndexSet
    private let labels: [UInt8]                 // low-resolution label map, 0 = background
    private let labelWidth: Int
    private let labelHeight: Int
    private let makeMask: (IndexSet) throws -> CIImage

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        if #available(iOS 17.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            do { try handler.perform([request]) } catch {
                throw CleanFailure("ما قدرت أفصل الخلفية على هذا الجهاز")
            }
            guard let result = request.results?.first, !result.allInstances.isEmpty else {
                throw CleanFailure("ما لقيت شخص أو شي واضح أفصله عن الخلفية")
            }
            (labels, labelWidth, labelHeight) = Self.copy(result.instanceMask) { $0 }
            allInstances = result.allInstances
            makeMask = { instances in
                CIImage(cvPixelBuffer: try result.generateScaledMaskForImage(forInstances: instances, from: handler))
            }
        } else {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            do { try handler.perform([request]) } catch {
                throw CleanFailure("ما قدرت أفصل الخلفية على هذا الجهاز")
            }
            guard let buffer = request.results?.first?.pixelBuffer else {
                throw CleanFailure("ما لقيت شخص أفصله عن الخلفية (على هذا الإصدار تنفصل الأشخاص والخلفيات السادة بس)")
            }
            let copied = Self.copy(buffer) { $0 >= 128 ? 1 : 0 }
            guard copied.0.contains(1) else {
                throw CleanFailure("ما لقيت شخص أفصله عن الخلفية (على هذا الإصدار تنفصل الأشخاص والخلفيات السادة بس)")
            }
            (labels, labelWidth, labelHeight) = copied
            allInstances = IndexSet(integer: 1)
            let soft = CIImage(cvPixelBuffer: buffer)
            let sx = CGFloat(image.width) / soft.extent.width, sy = CGFloat(image.height) / soft.extent.height
            makeMask = { instances in
                guard instances.contains(1) else {
                    return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return soft.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
        }
    }

    private static func copy(_ buffer: CVPixelBuffer, _ map: (UInt8) -> UInt8) -> ([UInt8], Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return ([], 0, 0) }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = map(base[y * row + x]) } }
        return (out, w, h)
    }

    /// Reads the low-resolution label map (0 = background).
    private func withLabels<T>(_ body: (_ base: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ row: Int) -> T) -> T {
        labels.withUnsafeBufferPointer { body($0.baseAddress!, labelWidth, labelHeight, labelWidth) }
    }

    /// Instance under a normalized point (top-left origin), or nil for background.
    func instance(at p: CGPoint) -> Int? {
        withLabels { base, w, h, row in
            let x = min(max(Int(p.x * Double(w)), 0), w - 1)
            let y = min(max(Int(p.y * Double(h)), 0), h - 1)
            let label = Int(base[y * row + x])
            return label == 0 ? nil : label
        }
    }

    /// A point inside the instance (its centre of mass when that lies inside), normalized.
    func anchor(of instance: Int) -> CGPoint? {
        withLabels { base, w, h, row in
            var sx = 0.0, sy = 0.0, n = 0.0
            var first: (Int, Int)? = nil
            for y in 0..<h { for x in 0..<w where Int(base[y * row + x]) == instance {
                sx += Double(x); sy += Double(y); n += 1
                if first == nil { first = (x, y) }
            } }
            guard n > 0 else { return nil }
            var cx = Int(sx / n), cy = Int(sy / n)
            if Int(base[cy * row + cx]) != instance, let f = first { (cx, cy) = f }   // e.g. ring-shaped subjects
            return CGPoint(x: (Double(cx) + 0.5) / Double(w), y: (Double(cy) + 0.5) / Double(h))
        }
    }

    /// Bounding box of the given instances, normalized (top-left origin).
    func boundingBox(of instances: IndexSet) -> CGRect? {
        withLabels { base, w, h, row in
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h { for x in 0..<w where instances.contains(Int(base[y * row + x])) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            guard maxX >= minX else { return nil }
            return CGRect(x: Double(minX) / Double(w), y: Double(minY) / Double(h),
                          width: Double(maxX - minX + 1) / Double(w), height: Double(maxY - minY + 1) / Double(h))
        }
    }

    /// Soft mask of the given instances at the full image size.
    func mask(for instances: IndexSet) throws -> CIImage {
        try makeMask(instances)
    }
}

// MARK: - Tools

enum ImageTools {

    static let maxSide = 8000
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Set by the Share Extension, which has a much smaller memory limit than the app.
    nonisolated(unsafe) static var pixelLimit: Int? = nil

    // MARK: Entry points

    /// Full-quality edit of a cleaned file.
    static func apply(_ options: EditOptions, to data: Data, currentExtension: String) throws -> EditResult {
        let image = try decode(data, maxSide: nil)
        let result = try process(image, options)
        var warnings = result.warnings
        var notes = result.notes
        var output = result.image

        let current = OutputFormat(fileExtension: currentExtension)
        var format = options.format ?? current ?? (result.transparent ? .png : .jpeg)
        if options.format == nil && result.transparent && !format.supportsTransparency {
            format = .png                                    // keep the new transparency
        }
        if !format.supportsTransparency && result.transparent {
            output = try render(output, width: output.width, height: output.height,
                                background: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            if options.removeBackground {
                warnings.append("صيغة JPG ما تدعم الشفافية — صارت الخلفية بيضاء")
                notes = notes.map { $0 == "خلفية شفافة" ? "خلفية بيضاء" : $0 }
            }
        }
        if options.format != nil || format != current {
            notes.insert(format.isLossy ? "\(format.title) \(Int((options.quality * 100).rounded()))٪" : format.title, at: 0)
        }

        let encoded = format == .svg
            ? try Vectorizer.trace(output)
            : try encode(output, as: format, quality: options.quality)
        // The encoder may add its own tags -> clean the new file the same way as any input.
        let again = try CleanerCore.clean(encoded, originalName: "image.\(format.ext)")
        return EditResult(data: again.data, fileExtension: again.fileExtension,
                          note: notes.joined(separator: "، "), warnings: warnings)
    }

    /// The editing steps on decoded pixels. Used for both the live preview and the final result.
    static func process(_ input: CGImage, _ o: EditOptions, analysis: SubjectAnalysis? = nil) throws -> Processed {
        var image = input
        var transparent = hasAlpha(image)
        var notes: [String] = []
        var warnings: [String] = []

        if o.removeBackground {
            var px = RGBAImage(image)
            let w = px.width, h = px.height
            let extent = CGRect(x: 0, y: 0, width: w, height: h)

            // Plain background (logos, icons, products on white…) -> colour flood fill.
            // Otherwise (or when the user picked subjects) -> Vision subject mask.
            let existing = Cutout.existingAlpha(px)
            let plain = existing == nil && o.excludedPoints.isEmpty ? Cutout.detectPlain(px) : nil
            var alpha: [Float]
            if let existing {
                alpha = existing                       // already cut out: keep it exactly as it is
            } else if let plain {
                alpha = Cutout.plainAlpha(px, plain, everywhere: o.removeEnclosedBackground)
            } else {
                let a = try analysis ?? SubjectAnalysis(image: image)
                var keep = a.allInstances
                for p in o.excludedPoints {
                    if let i = a.instance(at: p) { keep.remove(i) }
                }
                guard !keep.isEmpty else { throw CleanFailure("شلت كل العناصر — خلّ واحد على الأقل") }
                guard let va = Cutout.visionAlpha(try a.mask(for: keep), width: w, height: h) else {
                    throw CleanFailure("ما قدرت أفصل الخلفية")
                }
                alpha = va
            }
            guard alpha.contains(where: { $0 > 0.5 }), alpha.contains(where: { $0 < 0.5 }) else {
                throw CleanFailure("ما لقيت خلفية واضحة أفصلها عن الموضوع")
            }
            if o.edgeSoftness > 0 {
                alpha = Cutout.soften(alpha, width: w, height: h, amount: o.edgeSoftness)
            }
            if existing == nil {                       // its edges were never mixed with a background
                Cutout.decontaminate(&px, alpha: alpha, plain: plain)
            }
            guard let cut = px.makeImage(alpha: alpha) else { throw CleanFailure("ما قدرت أفصل الخلفية") }

            switch o.background {
            case .transparent:
                image = cut
                transparent = true
                notes.append("خلفية شفافة")
            case .color(let color):
                let bg = CIImage(color: CIColor(cgColor: color)).cropped(to: extent)
                guard let out = context.createCGImage(CIImage(cgImage: cut).composited(over: bg), from: extent,
                                                      format: .RGBA8, colorSpace: rgbSpace(of: image)) else {
                    throw CleanFailure("ما قدرت أفصل الخلفية")
                }
                image = out
                transparent = false
                notes.append("خلفية ملوّنة")
            case .blur(let amount):
                let sigma = max(2, amount * Double(min(w, h)) * 0.03)
                let bg = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
                guard let out = context.createCGImage(CIImage(cgImage: cut).composited(over: bg), from: extent,
                                                      format: .RGBA8, colorSpace: rgbSpace(of: image)) else {
                    throw CleanFailure("ما قدرت أفصل الخلفية")
                }
                image = out
                transparent = false
                notes.append("خلفية مموّهة")
            }

            if o.cropToSubject, let box = Cutout.subjectBox(alpha: alpha, width: w, height: h) {
                let m = o.subjectMargin * max(box.width, box.height)
                let r = box.insetBy(dx: -m, dy: -m).integral.intersection(extent)
                if let cropped = image.cropping(to: r) { image = cropped }
                notes.append("قص على الموضوع")
            }
        }

        if let size = o.size {
            let before = max(image.width, image.height)
            image = try resize(image, to: size, mode: o.resizeMode, focus: o.focus, crop: o.crop)
            if max(image.width, image.height) > before {
                warnings.append("الصورة أصغر من المقاس فتم تكبيرها — ممكن تقل حدتها")
            }
            notes.append("\u{2066}\(image.width)×\(image.height)\u{2069}")   // keep "W×H" left-to-right in Arabic text
        }

        return Processed(image: image, transparent: transparent, notes: notes, warnings: warnings)
    }

    // MARK: Decode / encode

    /// Decodes with the orientation applied (so outputs need no Orientation tag).
    static func decode(_ data: Data, maxSide limit: Int?) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw CleanFailure("ما قدرت أفتح الصورة للتعديل") }
        if limit == nil, let cap = pixelLimit, w * h > cap {
            throw CleanFailure("الصورة كبيرة على المشاركة السريعة — عدّلها من داخل التطبيق")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), limit ?? Int.max),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw CleanFailure("ما قدرت أفتح الصورة للتعديل")
        }
        return image
    }

    static func encode(_ image: CGImage, as format: OutputFormat, quality: Double) throws -> Data {
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let out = NSMutableData()
        guard supported.contains(format.typeIdentifier),
              let dst = CGImageDestinationCreateWithData(out as CFMutableData, format.typeIdentifier as CFString, 1, nil)
        else { throw CleanFailure("هذا الجهاز ما يقدر يحفظ بصيغة \(format.title)") }
        var props: [CFString: Any] = [:]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw CleanFailure("ما قدرت أحفظ الصورة بصيغة \(format.title)") }
        return out as Data
    }

    // MARK: Resize

    static func resize(_ image: CGImage, to target: SizeTarget, mode: ResizeMode, focus: CGPoint?, crop userCrop: CGRect? = nil) throws -> CGImage {
        let w = Double(image.width), h = Double(image.height)
        var crop = CGRect(x: 0, y: 0, width: w, height: h)
        var outW: Double, outH: Double

        switch target {
        case .scale(let s):
            outW = w * s
            outH = h * s
        case .pixels(let tw, let th):
            guard tw > 0, th > 0 else { throw CleanFailure("المقاس غير صحيح") }
            if mode == .fit {
                let s = min(Double(tw) / w, Double(th) / h)
                outW = w * s
                outH = h * s
            } else {
                let n = userCrop ?? cropRect(imageWidth: w, imageHeight: h, targetWidth: tw, targetHeight: th,
                                             focus: focus ?? autoFocus(image))
                crop = CGRect(x: n.minX * w, y: n.minY * h, width: n.width * w, height: n.height * h).integral
                    .intersection(CGRect(x: 0, y: 0, width: w, height: h))
                outW = Double(tw)
                outH = Double(th)
            }
        }

        let width = max(1, Int(outW.rounded())), height = max(1, Int(outH.rounded()))
        guard width <= maxSide, height <= maxSide else {
            throw CleanFailure("المقاس كبير — الحد \(maxSide) بكسل لكل جهة")
        }
        guard let part = image.cropping(to: crop) else { throw CleanFailure("ما قدرت أقص الصورة") }
        if let scaled = try? scaleHighQuality(part, width: width, height: height) { return scaled }
        return try render(part, width: width, height: height, background: nil)
    }

    /// Lanczos resampling (Accelerate / vImage) — the same filter photo editors use;
    /// much sharper and cleaner than CoreGraphics' interpolation when shrinking.
    static func scaleHighQuality(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let format = vImage_CGImageFormat(cgImage: image), format.bitsPerPixel == 32 else {
            throw CleanFailure("صيغة غير مدعومة للتصغير")
        }
        var src = try vImage_Buffer(cgImage: image, format: format)
        defer { src.free() }
        var dst = try vImage_Buffer(width: width, height: height, bitsPerPixel: format.bitsPerPixel)
        defer { dst.free() }
        let err = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        guard err == kvImageNoError else { throw CleanFailure("ما قدرت أصغّر الصورة") }
        return try dst.createCGImage(format: format)
    }

    /// The part of the image kept by a smart crop, normalized (top-left origin).
    static func cropRect(imageWidth w: Double, imageHeight h: Double, targetWidth tw: Int, targetHeight th: Int, focus: CGPoint) -> CGRect {
        let aspect = Double(tw) / Double(th)
        let cw = w / h > aspect ? h * aspect : w
        let ch = w / h > aspect ? h : w / aspect
        let x = min(max(focus.x * w - cw / 2, 0), w - cw)
        let y = min(max(focus.y * h - ch / 2, 0), h - ch)
        return CGRect(x: x / w, y: y / h, width: cw / w, height: ch / h)
    }

    /// Smart crop zoomed in by `zoom` (1 = the largest crop of the target shape) around `center`.
    static func cropRect(imageWidth w: Double, imageHeight h: Double, targetWidth tw: Int, targetHeight th: Int,
                         center: CGPoint, zoom: Double) -> CGRect {
        let base = cropRect(imageWidth: w, imageHeight: h, targetWidth: tw, targetHeight: th, focus: center)
        let z = max(1, zoom)
        let cw = base.width / z, ch = base.height / z
        let x = min(max(center.x - cw / 2, 0), 1 - cw)
        let y = min(max(center.y - ch / 2, 0), 1 - ch)
        return CGRect(x: x, y: y, width: cw, height: ch)
    }

    /// Centre of the part people look at first (faces, the main subject), normalized.
    static func autoFocus(_ image: CGImage) -> CGPoint {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let boxes = request.results?.first?.salientObjects?.map(\.boundingBox), let first = boxes.first else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let box = boxes.dropFirst().reduce(first) { $0.union($1) }   // normalized, origin bottom-left
        return CGPoint(x: box.midX, y: 1 - box.midY)
    }

    // MARK: Helpers

    static func render(_ image: CGImage, width: Int, height: Int, background: CGColor?) throws -> CGImage {
        // Opaque results are stored without an alpha channel (smaller files, no fake transparency).
        let opaque = background != nil || !hasAlpha(image)
        let info = (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: rgbSpace(of: image), bitmapInfo: info)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: srgb, bitmapInfo: info)
        else { throw CleanFailure("ما قدرت أجهّز الصورة") }
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            ctx.setFillColor(background)
            ctx.fill(rect)
        }
        ctx.draw(image, in: rect)
        guard let out = ctx.makeImage() else { throw CleanFailure("ما قدرت أجهّز الصورة") }
        return out
    }

    static func rgbSpace(of image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
        default: return false
        }
    }
}
