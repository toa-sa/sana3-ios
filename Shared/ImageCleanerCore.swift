//
//  ImageCleanerCore.swift
//  Image Cleaner — TOA
//
//  Removes all metadata from images WITHOUT re-encoding. The compressed
//  pixel data is copied byte-for-byte, so resolution and quality stay
//  100% identical. Also runs a security scan on everything it removes.
//
//  JPEG / PNG / WebP  -> own byte-level parser (exact port of clean.py)
//  HEIC / HEIF / TIFF -> ImageIO lossless metadata rewrite
//

import Foundation
import Compression
import ImageIO
import UniformTypeIdentifiers

struct CleanResult {
    let data: Data
    let fileExtension: String
    let warnings: [String]
}

struct CleanFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum CleanerCore {

    // MARK: - Public entry point

    static func clean(_ input: Data, originalName: String?) throws -> CleanResult {
        let d = [UInt8](input)
        let ext = (originalName.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
        guard d.count >= 12 else { throw CleanFailure("الملف صغير جداً أو فاضي") }
        guard d.count <= maxInputBytes else {
            throw CleanFailure("الملف كبير جداً (\(sizeText(d.count))) — الحد \(sizeText(maxInputBytes))")
        }
        var warnings: [String] = []

        if let kind = detect(d) {
            if !ext.isEmpty, !kind.extensions.contains(ext) {
                warnings.append("الامتداد .\(ext) لا يطابق نوعها الحقيقي (.\(kind.ext)) — تم تصحيحه")
            }
            let r = try kind.clean(d)
            warnings += r.issues
            let found = scan(r.removed)
            if !found.isEmpty {
                warnings.append("محتوى مشبوه داخل البيانات المخفية: \(found.joined(separator: "، ")) — تمت إزالته")
            }
            try checkDimensions(r.width, r.height)
            // A colour profile is a small, structured file — code or archives inside one are an attack.
            let inProfile = scan(r.kept)
            guard inProfile.isEmpty, r.kept.count <= 4_000_000 else {
                throw CleanFailure("ملف الألوان (ICC) داخل الصورة فيه محتوى مشبوه: \(inProfile.joined(separator: "، ")) — تم رفضها")
            }
            // Verify: cleaning the output again must give identical bytes and nothing suspicious.
            let again = try kind.clean(r.output)
            guard again.output == r.output, scan(again.removed).isEmpty else {
                throw CleanFailure("فشل التحقق من النسخة النظيفة")
            }
            return CleanResult(data: Data(r.output), fileExtension: kind.ext, warnings: warnings)
        }

        if looksLikeSVG(d) {
            // Rebuilt from an allow-list (scripts, links, entities, metadata removed), then verified.
            let r = try SVGSanitizer.clean(input)
            if !ext.isEmpty, ext != "svg" {
                warnings.append("الامتداد .\(ext) لا يطابق نوعها الحقيقي (.svg) — تم تصحيحه")
            }
            let again = try SVGSanitizer.clean(r.data)
            guard again.data == r.data, again.warnings.isEmpty else { throw CleanFailure("فشل التحقق من نسخة SVG النظيفة") }
            return CleanResult(data: r.data, fileExtension: "svg", warnings: warnings + r.warnings)
        }
        if isISOBMFF(d) || isTIFF(d) {
            return try cleanWithImageIO(input, bytes: d, ext: ext, warnings: warnings)
        }
        throw CleanFailure("الملف ما هو صورة حقيقية أو صيغته غير مدعومة")
    }

    // MARK: - Kinds

    enum Kind {
        case jpeg, png, webp

        var ext: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .webp: return "webp"
            }
        }

        var extensions: Set<String> {
            switch self {
            case .jpeg: return ["jpg", "jpeg", "jpe", "jfif"]
            case .png: return ["png"]
            case .webp: return ["webp"]
            }
        }

        func clean(_ d: [UInt8]) throws -> Parsed {
            switch self {
            case .jpeg: return try CleanerCore.cleanJPEG(d)
            case .png: return try CleanerCore.cleanPNG(d)
            case .webp: return try CleanerCore.cleanWebP(d)
            }
        }
    }

    struct Parsed {
        var output: [UInt8]
        var removed: [UInt8]
        var issues: [String]
        var width: Int
        var height: Int
        /// Colour profiles that are KEPT — checked too, so nothing can hide inside them.
        var kept: [UInt8] = []
    }

    static func detect(_ d: [UInt8]) -> Kind? {
        if d.count >= 3, d[0] == 0xFF, d[1] == 0xD8, d[2] == 0xFF { return .jpeg }
        if has(d, 0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if has(d, 0, ascii("RIFF")), has(d, 8, ascii("WEBP")) { return .webp }
        return nil
    }

    static func isISOBMFF(_ d: [UInt8]) -> Bool { has(d, 4, ascii("ftyp")) }

    static func isTIFF(_ d: [UInt8]) -> Bool {
        has(d, 0, [0x49, 0x49, 0x2A, 0x00]) || has(d, 0, [0x4D, 0x4D, 0x00, 0x2A])
    }

    static func looksLikeSVG(_ d: [UInt8]) -> Bool {
        let head = lowercased(Array(d.prefix(1024)))
        return find(head, ascii("<svg")) || has(head, 0, ascii("<?xml"))
    }

    static let corrupt = CleanFailure("بنية الصورة تالفة أو متلاعب فيها")
    static let noImage = CleanFailure("ما فيها بيانات صورة صالحة")
    static let truncated = "الصورة ناقصة (ما لها نهاية صحيحة)"

    // MARK: - JPEG

    static func cleanJPEG(_ d: [UInt8]) throws -> Parsed {
        var kept: [UInt8] = []
        let n = d.count
        guard n > 4, d[0] == 0xFF, d[1] == 0xD8 else { throw corrupt }
        var head: [[UInt8]] = []
        var body: [[UInt8]] = []
        var orientation = 1
        var adobe: [UInt8]? = nil
        var removed: [UInt8] = []
        var issues: [String] = []
        var dims: (w: Int, h: Int)? = nil
        var ended = false
        var i = 2

        markerLoop: while i < n {
            guard d[i] == 0xFF else { throw corrupt }
            while i + 1 < n && d[i + 1] == 0xFF { i += 1 }
            guard i + 1 < n else { break }
            let m = d[i + 1]

            if m == 0xD9 {                                   // EOI -> stop, drop any trailer
                let trailer = Array(d[(i + 2)...])
                if trailer.contains(where: { $0 != 0 }) {
                    issues.append("بيانات مخفية بعد نهاية الصورة (\(sizeText(trailer.count)))")
                    removed += trailer
                }
                ended = true
                break
            }
            if (0xD0...0xD7).contains(m) || m == 0x01 {      // standalone markers
                body.append([0xFF, m]); i += 2; continue
            }
            guard i + 4 <= n else { throw corrupt }
            let length = be16(d, i + 2)
            guard length >= 2, i + 2 + length <= n else { throw corrupt }
            let seg = Array(d[i..<(i + 2 + length)])
            i += 2 + length

            if m == 0xDA {                                   // SOS + entropy-coded data
                var j = i
                while j + 1 < n {
                    if d[j] == 0xFF && d[j + 1] != 0x00 && !(0xD0...0xD7).contains(d[j + 1]) { break }
                    j += 1
                }
                if j + 1 >= n {                              // no marker until end of file
                    body.append(seg + d[i..<n])
                    i = n
                    break markerLoop
                }
                body.append(seg + d[i..<j])
                i = j
                continue
            }

            let isSOF = (0xC0...0xCF).contains(m) && m != 0xC4 && m != 0xC8 && m != 0xCC
            if m == 0xE0 && has(seg, 4, ascii("JFIF\u{0}")) {
                // rebuild JFIF header without thumbnail
                if seg.count >= 16 {
                    var jfif: [UInt8] = [0xFF, 0xE0, 0x00, 0x10]
                    jfif.append(contentsOf: seg[4..<16])
                    jfif.append(contentsOf: [0x00, 0x00])
                    head.append(jfif)
                }
                if seg.count > 18 { removed += Array(seg[18...]) }
            } else if m == 0xE1 && has(seg, 4, ascii("Exif\u{0}\u{0}")) {
                orientation = exifOrientation(Array(seg[10...]))
                removed += seg
            } else if m == 0xE2 && has(seg, 4, ascii("ICC_PROFILE\u{0}")) {
                body.append(seg)                             // color profile -> keep
                kept += seg
            } else if m == 0xEE && has(seg, 4, ascii("Adobe")) {
                adobe = seg                                  // decide at SOF
            } else if [0xDB, 0xC4, 0xDD, 0xCC].contains(m) || isSOF {
                if isSOF {
                    guard seg.count >= 10 else { throw corrupt }
                    if dims == nil { dims = (w: be16(seg, 7), h: be16(seg, 5)) }
                    if let a = adobe {
                        let comps = Int(seg[9])
                        let transform = a.count > 15 ? Int(a[15]) : 1
                        if comps == 4 || transform != 1 { body.append(a) }   // needed for correct colors
                        adobe = nil
                    }
                }
                body.append(seg)
            } else {
                // APP1 XMP, APP11 C2PA/JUMBF, APP13 IPTC/Photoshop, COM, ... -> dropped
                removed += seg
            }
        }

        if !ended { issues.append(truncated) }
        guard let size = dims else { throw noImage }

        var out: [UInt8] = [0xFF, 0xD8]
        for s in head { out += s }
        if orientation != 1 {
            var tiff = ascii("Exif\u{0}\u{0}")
            tiff.append(contentsOf: minimalExif(orientation))
            out.append(contentsOf: [0xFF, 0xE1])
            out.append(contentsOf: u16be(tiff.count + 2))
            out.append(contentsOf: tiff)
        }
        for s in body { out += s }
        out += [0xFF, 0xD9]
        return Parsed(output: out, removed: removed, issues: issues, width: size.w, height: size.h, kept: kept)
    }

    // MARK: - PNG

    static let pngKeep: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB",
                                       "iCCP", "sBIT", "cICP", "mDCV", "cLLI", "acTL", "fcTL", "fdAT"]
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func cleanPNG(_ d: [UInt8]) throws -> Parsed {
        var kept: [UInt8] = []
        guard has(d, 0, pngSignature) else { throw corrupt }
        var inflatedTotal = 0
        var chunks: [(type: String, raw: [UInt8])] = []
        var orientation = 1
        var removed: [UInt8] = []
        var issues: [String] = []
        var dims: (w: Int, h: Int)? = nil
        var ended = false
        var i = 8

        while i + 8 <= d.count {
            let length = be32(d, i)
            let type = String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self)
            guard length >= 0, i + 12 + length <= d.count else { throw corrupt }
            let raw = Array(d[i..<(i + 12 + length)])
            let storedCRC = UInt32(be32(d, i + 8 + length))
            let crcOK = crc32(d[(i + 4)..<(i + 8 + length)]) == storedCRC

            if type == "IHDR" {
                guard length >= 8, i == 8, dims == nil else { throw corrupt }   // first chunk, exactly once
                dims = (w: be32(d, i + 8), h: be32(d, i + 12))
            }
            if type == "eXIf" {
                orientation = exifOrientation(Array(d[(i + 8)..<(i + 8 + length)]))
                removed += raw
            } else if pngKeep.contains(type) {
                guard crcOK else { throw CleanFailure("جزء \(type) تالف أو متلاعب فيه") }
                chunks.append((type: type, raw: raw))
                if type == "iCCP" { kept += inflatedText("zTXt", Array(d[(i + 8)..<(i + 8 + length)])) }
            } else {
                removed += raw                               // tEXt/iTXt/zTXt prompts, caBX (C2PA), ...
                if (type == "zTXt" || type == "iTXt") && inflatedTotal < maxInflate * 2 {   // scan what it really contains
                    let text = inflatedText(type, Array(d[(i + 8)..<(i + 8 + length)]))
                    inflatedTotal += text.count
                    removed += text
                }
            }
            i += 12 + length
            if type == "IEND" { ended = true; break }
        }

        let trailer = Array(d[min(i, d.count)...])
        if trailer.contains(where: { $0 != 0 }) {
            issues.append("بيانات مخفية بعد نهاية الصورة (\(sizeText(trailer.count)))")
            removed += trailer
        }
        if !ended { issues.append(truncated) }
        guard let size = dims else { throw noImage }

        var out = pngSignature
        var passedFirstIDAT = false
        for chunk in chunks {
            if chunk.type == "IDAT" && !passedFirstIDAT {
                if orientation != 1 {
                    var typeAndData = ascii("eXIf")
                    typeAndData.append(contentsOf: minimalExif(orientation))
                    out.append(contentsOf: u32be(typeAndData.count - 4))
                    out.append(contentsOf: typeAndData)
                    out.append(contentsOf: u32be(Int(crc32(typeAndData))))
                }
                passedFirstIDAT = true
            }
            out += chunk.raw
        }
        return Parsed(output: out, removed: removed, issues: issues, width: size.w, height: size.h, kept: kept)
    }

    // MARK: - WebP

    static let webpKeep: Set<String> = ["VP8 ", "VP8L", "VP8X", "ALPH", "ANIM", "ANMF", "ICCP"]

    static func cleanWebP(_ d: [UInt8]) throws -> Parsed {
        var kept: [UInt8] = []
        guard has(d, 0, ascii("RIFF")), has(d, 8, ascii("WEBP")) else { throw corrupt }
        let end = 8 + le32(d, 4)
        guard end <= d.count, end >= 12 else { throw corrupt }
        var body: [UInt8] = []
        var removed: [UInt8] = []
        var issues: [String] = []
        var dims: (w: Int, h: Int)? = nil
        var i = 12

        while i + 8 <= end {
            let type = String(decoding: d[i..<(i + 4)], as: UTF8.self)
            let length = le32(d, i + 4)
            guard i + 8 + length <= end else { throw corrupt }
            let padded = length + (length & 1)
            var raw = Array(d[i..<min(i + 8 + padded, end)])
            while raw.count < 8 + padded { raw.append(0) }

            if type == "VP8X", raw.count >= 18 {
                dims = (w: le24(raw, 12) + 1, h: le24(raw, 15) + 1)
            } else if type == "VP8 ", dims == nil, length >= 10, raw.count >= 18 {
                dims = (w: le16(raw, 14) & 0x3FFF, h: le16(raw, 16) & 0x3FFF)
            } else if type == "VP8L", dims == nil, length >= 5, raw.count >= 13 {
                let b = le32(raw, 9)
                dims = (w: (b & 0x3FFF) + 1, h: ((b >> 14) & 0x3FFF) + 1)
            }

            if webpKeep.contains(type) {
                if type == "VP8X", raw.count > 8 { raw[8] &= ~UInt8(0x08 | 0x04) }   // clear EXIF + XMP flags
                if type == "ICCP" { kept += raw }
                body += raw
            } else {
                removed += raw                               // EXIF, XMP, unknown chunks
            }
            i += 8 + padded
        }

        let trailer = Array(d[min(end, d.count)...])
        if trailer.contains(where: { $0 != 0 }) {
            issues.append("بيانات مخفية بعد نهاية الصورة (\(sizeText(trailer.count)))")
            removed += trailer
        }
        guard let size = dims else { throw noImage }

        var out = ascii("RIFF")
        out.append(contentsOf: u32le(body.count + 4))
        out.append(contentsOf: ascii("WEBP"))
        out.append(contentsOf: body)
        return Parsed(output: out, removed: removed, issues: issues, width: size.w, height: size.h, kept: kept)
    }

    // MARK: - HEIC / HEIF / TIFF via ImageIO (lossless)

    static func cleanWithImageIO(_ data: Data, bytes d: [UInt8], ext: String, warnings: [String]) throws -> CleanResult {
        var warnings = warnings
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { throw CleanFailure("الملف ما هو صورة حقيقية أو تالف") }

        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        try checkDimensions(w, h)
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, type, CGImageSourceGetCount(src), nil) else {
            throw CleanFailure("ما قدرت أجهّز النسخة النظيفة")
        }
        // Always write the Orientation tag: ImageIO treats EMPTY metadata as "keep the original",
        // so the replacement metadata must contain at least one value for EXIF/GPS/XMP to be dropped.
        let meta = CGImageMetadataCreateMutable()
        _ = CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation,
                                                         NSNumber(value: orientation))
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        // CopyImageSource rewrites metadata WITHOUT recompressing the image. Do not call Finalize.
        guard CGImageDestinationCopyImageSource(dst, src, options as CFDictionary, nil) else {
            throw CleanFailure("هالصيغة ما تتنظف بدون إعادة ضغط على هذا الجهاز")
        }
        var outBytes = [UInt8](out as Data)
        if isISOBMFF(outBytes) {
            // ImageIO keeps XMP items in HEIF even with replacement metadata -> remove them ourselves.
            outBytes = try stripHEIFItems(outBytes)
        }
        let cleaned = Data(outBytes)

        // Security scan: compare suspicious content before / after
        let before = scan(d, strongOnly: true)
        let after = scan(outBytes, strongOnly: true)
        let gone = before.filter { !after.contains($0) }
        if !gone.isEmpty {
            warnings.append("محتوى مشبوه داخل الملف: \(gone.joined(separator: "، ")) — تمت إزالته")
        }
        if !after.isEmpty {
            warnings.append("محتوى مشبوه ما انشال: \(after.joined(separator: "، ")) — لا تستخدم الصورة")
        }

        // Verify nothing identifying is left
        guard let s2 = CGImageSourceCreateWithData(cleaned as CFData, nil),
              let p2 = CGImageSourceCopyPropertiesAtIndex(s2, 0, nil) as? [CFString: Any],
              (p2[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == w,
              (p2[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == h
        else { throw CleanFailure("فشل التحقق من النسخة النظيفة") }

        var left: [String] = []
        if p2[kCGImagePropertyGPSDictionary] != nil { left.append("الموقع GPS") }
        if let tiff = p2[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil || tiff[kCGImagePropertyTIFFSoftware] != nil {
            left.append("بيانات الجهاز/البرنامج")
        }
        if let exif = p2[kCGImagePropertyExifDictionary] as? [CFString: Any],
           exif[kCGImagePropertyExifDateTimeOriginal] != nil || exif[kCGImagePropertyExifLensModel] != nil {
            left.append("بيانات EXIF")
        }
        if p2[kCGImagePropertyMakerAppleDictionary] != nil { left.append("بيانات Apple الخاصة") }
        let lowerOut = lowercased(outBytes)
        if find(lowerOut, ascii("c2pa")) && find(lowerOut, ascii("jumb")) { left.append("توقيع Content Credentials") }
        if !left.isEmpty {
            warnings.append("بقت بعض البيانات: \(left.joined(separator: "، ")) — جرّب تحفظ الصورة JPEG ثم نظّفها")
        }

        let outExt = UTType(type as String)?.preferredFilenameExtension ?? (ext.isEmpty ? "heic" : ext)
        return CleanResult(data: cleaned, fileExtension: outExt, warnings: warnings)
    }

    // MARK: - HEIF metadata items

    struct Box {
        let type: String
        let start: Int
        let header: Int
        let end: Int
        var payload: Range<Int> { (start + header)..<end }
    }

    static func boxes(_ d: [UInt8], _ range: Range<Int>) throws -> [Box] {
        var list: [Box] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard i + 8 <= range.upperBound else { throw corrupt }
            var size = be32(d, i)
            var header = 8
            if size == 1 {
                guard i + 16 <= range.upperBound, be32(d, i + 8) == 0 else { throw corrupt }   // > 4 GB: not for us
                size = be32(d, i + 12)
                header = 16
            } else if size == 0 {
                size = range.upperBound - i
            }
            guard size >= header, size <= range.upperBound - i else { throw corrupt }
            list.append(Box(type: String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self), start: i, header: header, end: i + size))
            i += size
        }
        return list
    }

    static func skip(_ p: inout Int, _ n: Int, _ end: Int) throws {
        guard n >= 0, p <= end, n <= end - p else { throw corrupt }
        p += n
    }

    static func makeBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        u32be(payload.count + 8) + ascii(type) + payload
    }

    static func readUInt(_ d: [UInt8], _ i: inout Int, _ size: Int, limit: Int) throws -> Int {
        guard [0, 1, 2, 4, 8].contains(size), i >= 0, i <= limit, size <= limit - i else { throw corrupt }
        var v = 0
        for k in 0..<size { v = v << 8 | Int(d[i + k]) }
        i += size
        guard v >= 0, v <= Int(UInt32.max) * 4 else { throw corrupt }     // no file offset is this large
        return v
    }

    static func readCString(_ d: [UInt8], _ i: inout Int, limit: Int) -> String {
        let s = i
        while i < limit && d[i] != 0 { i += 1 }
        let text = String(decoding: d[s..<i], as: UTF8.self)
        if i < limit { i += 1 }
        return text
    }

    /// Removes every 'mime' / 'uri ' item (XMP, C2PA, ...) from a HEIF file and blanks its bytes.
    /// XMP that only describes an auxiliary image (e.g. the HDR gain map) is kept so HDR still works.
    /// The rebuilt 'meta' box is followed by a 'free' box of the saved size, so no item offset moves
    /// and the compressed image data stays byte-for-byte identical.
    static func stripHEIFItems(_ input: [UInt8]) throws -> [UInt8] {
        var d = input
        guard let meta = try boxes(d, 0..<d.count).first(where: { $0.type == "meta" }), meta.header == 8,
              meta.end - meta.payload.lowerBound >= 4 else { throw corrupt }
        let children = try boxes(d, (meta.payload.lowerBound + 4)..<meta.end)

        // Items
        var itemType: [Int: String] = [:]
        if let iinf = children.first(where: { $0.type == "iinf" }) {
            var p = iinf.payload.lowerBound
            let version = try readUInt(d, &p, 1, limit: iinf.end); try skip(&p, 3, iinf.end)
            _ = try readUInt(d, &p, version == 0 ? 2 : 4, limit: iinf.end)
            for infe in try boxes(d, p..<iinf.end) where infe.type == "infe" {
                var q = infe.payload.lowerBound
                let v = try readUInt(d, &q, 1, limit: infe.end); try skip(&q, 3, infe.end)
                guard v >= 2 else { continue }
                let id = try readUInt(d, &q, v == 2 ? 2 : 4, limit: infe.end)
                try skip(&q, 2, infe.end)
                guard q + 4 <= infe.end else { throw corrupt }
                itemType[id] = String(decoding: d[q..<(q + 4)], as: UTF8.self)
            }
        }

        // References
        var refs: [(type: String, from: Int, to: [Int])] = []
        var irefVersion = 0
        if let iref = children.first(where: { $0.type == "iref" }) {
            var p = iref.payload.lowerBound
            irefVersion = try readUInt(d, &p, 1, limit: iref.end); try skip(&p, 3, iref.end)
            let idSize = irefVersion == 0 ? 2 : 4
            for ref in try boxes(d, p..<iref.end) {
                var q = ref.payload.lowerBound
                let from = try readUInt(d, &q, idSize, limit: ref.end)
                let count = try readUInt(d, &q, 2, limit: ref.end)
                var to: [Int] = []
                for _ in 0..<count { to.append(try readUInt(d, &q, idSize, limit: ref.end)) }
                refs.append((type: ref.type, from: from, to: to))
            }
        }

        // Item data (needed to look inside the XMP that describes auxiliary images)
        guard let ilocBox = children.first(where: { $0.type == "iloc" }) else { throw corrupt }
        let idatBox = children.first(where: { $0.type == "idat" })
        var itemBytes: [Int: [UInt8]] = [:]
        do {
            var q = ilocBox.payload.lowerBound
            let v = try readUInt(d, &q, 1, limit: ilocBox.end); try skip(&q, 3, ilocBox.end)
            let sz = try readUInt(d, &q, 2, limit: ilocBox.end)
            let oS = sz >> 12, lS = (sz >> 8) & 0xF, bS = (sz >> 4) & 0xF, iS = v >= 1 ? sz & 0xF : 0
            let n = try readUInt(d, &q, v < 2 ? 2 : 4, limit: ilocBox.end)
            guard [0, 4, 8].contains(oS), [0, 4, 8].contains(lS), [0, 4, 8].contains(bS), [0, 4, 8].contains(iS),
                  n <= 100_000 else { throw corrupt }
            var extentBudget = 200_000
            for _ in 0..<n {
                let id = try readUInt(d, &q, v < 2 ? 2 : 4, limit: ilocBox.end)
                let method = v >= 1 ? try readUInt(d, &q, 2, limit: ilocBox.end) & 0xF : 0
                try skip(&q, 2, ilocBox.end)
                let base = try readUInt(d, &q, bS, limit: ilocBox.end)
                let ext = try readUInt(d, &q, 2, limit: ilocBox.end)
                var bytes: [UInt8] = []
                extentBudget -= ext
                guard extentBudget >= 0 else { throw corrupt }
                for _ in 0..<ext {
                    try skip(&q, iS, ilocBox.end)
                    let off = try readUInt(d, &q, oS, limit: ilocBox.end)
                    let len = try readUInt(d, &q, lS, limit: ilocBox.end)
                    let origin = method == 1 ? (idatBox?.payload.lowerBound ?? -1) : 0
                    let (s1, o1) = origin.addingReportingOverflow(base)
                    let (s0, o2) = s1.addingReportingOverflow(off)
                    guard !o1, !o2 else { throw corrupt }
                    if itemType[id] == "mime", origin >= 0, method <= 1, s0 >= 0, len > 0, len <= d.count - min(s0, d.count), s0 < d.count, bytes.count < 1_000_000 {
                        bytes += d[s0..<(s0 + len)]
                    }
                }
                if itemType[id] == "mime" { itemBytes[id] = bytes }
            }
        }

        // Keep only the XMP that the HDR gain map needs to render (Apple HDRGainMap).
        // Everything else goes: XMP of the main image, C2PA, and XMP of depth / portrait maps
        // (lens calibration, intrinsic matrix… can fingerprint the camera).
        let auxItems = Set(refs.filter { $0.type == "auxl" }.map(\.from))
        let dropped = Set(itemType.filter { id, type in
            guard type == "mime" || type == "uri " else { return false }
            let described = refs.filter { $0.type == "cdsc" && $0.from == id }.flatMap(\.to)
            guard !described.isEmpty, described.allSatisfy({ auxItems.contains($0) }) else { return true }
            let text = lowercased(itemBytes[id] ?? [])
            let isGainMap = find(text, ascii("hdrgainmap"))
            let identifying = find(text, ascii("depthdata")) || find(text, ascii("lensdistortion"))
                || find(text, ascii("intrinsicmatrix")) || find(text, ascii("dc:creator")) || find(text, ascii("creatortool"))
            return !isGainMap || identifying
        }.keys)
        if dropped.isEmpty { return input }

        // Locations: keep the raw entries of the other items, blank the bytes of dropped ones
        guard let iloc = children.first(where: { $0.type == "iloc" }) else { throw corrupt }
        var p = iloc.payload.lowerBound
        let ilocVersion = try readUInt(d, &p, 1, limit: iloc.end); try skip(&p, 3, iloc.end)
        let sizes = try readUInt(d, &p, 2, limit: iloc.end)
        let offsetSize = sizes >> 12, lengthSize = (sizes >> 8) & 0xF
        let baseSize = (sizes >> 4) & 0xF, indexSize = ilocVersion >= 1 ? sizes & 0xF : 0
        let ilocHead = Array(d[iloc.payload.lowerBound..<p])
        let count = try readUInt(d, &p, ilocVersion < 2 ? 2 : 4, limit: iloc.end)
        let idat = children.first(where: { $0.type == "idat" })
        var keptEntries: [UInt8] = []
        var keptCount = 0
        var blank: [Range<Int>] = []
        for _ in 0..<count {
            let entryStart = p
            let id = try readUInt(d, &p, ilocVersion < 2 ? 2 : 4, limit: iloc.end)
            let method = ilocVersion >= 1 ? try readUInt(d, &p, 2, limit: iloc.end) & 0xF : 0
            try skip(&p, 2, iloc.end)                          // data_reference_index
            let base = try readUInt(d, &p, baseSize, limit: iloc.end)
            let extents = try readUInt(d, &p, 2, limit: iloc.end)
            for _ in 0..<extents {
                try skip(&p, indexSize, iloc.end)
                let offset = try readUInt(d, &p, offsetSize, limit: iloc.end)
                let length = try readUInt(d, &p, lengthSize, limit: iloc.end)
                guard dropped.contains(id) else { continue }
                let origin = method == 1 ? (idat?.payload.lowerBound ?? -1) : 0
                let (s1, o1) = origin.addingReportingOverflow(base)
                let (s, o2) = s1.addingReportingOverflow(offset)
                guard !o1, !o2, origin >= 0, method <= 1, length > 0, s >= 0, s < d.count, length <= d.count - s else { throw corrupt }
                blank.append(s..<(s + length))
            }
            if !dropped.contains(id) {
                keptEntries += d[entryStart..<p]
                keptCount += 1
            }
        }
        for r in blank { for k in r { d[k] = 0 } }

        // Rebuild 'meta' without the dropped items
        var newChildren: [UInt8] = []
        for child in children {
            switch child.type {
            case "iinf":
                var q = child.payload.lowerBound
                let version = try readUInt(d, &q, 1, limit: child.end); try skip(&q, 3, child.end)
                _ = try readUInt(d, &q, version == 0 ? 2 : 4, limit: child.end)
                var entries: [UInt8] = []
                var n = 0
                for infe in try boxes(d, q..<child.end) {
                    var r = infe.payload.lowerBound
                    let v = try readUInt(d, &r, 1, limit: infe.end); r += 3
                    if v >= 2, dropped.contains(try readUInt(d, &r, v == 2 ? 2 : 4, limit: infe.end)) { continue }
                    entries += d[infe.start..<infe.end]
                    n += 1
                }
                let head = Array(d[child.payload.lowerBound..<(child.payload.lowerBound + 4)])
                newChildren += makeBox("iinf", head + (version == 0 ? u16be(n) : u32be(n)) + entries)
            case "iref":
                var body: [UInt8] = [UInt8(irefVersion), 0, 0, 0]
                let idBytes: (Int) -> [UInt8] = { irefVersion == 0 ? u16be($0) : u32be($0) }
                for ref in refs where !dropped.contains(ref.from) {
                    let to = ref.to.filter { !dropped.contains($0) }
                    guard !to.isEmpty else { continue }
                    body += makeBox(ref.type, idBytes(ref.from) + u16be(to.count) + to.flatMap(idBytes))
                }
                if body.count > 4 { newChildren += makeBox("iref", body) }
            case "iloc":
                newChildren += makeBox("iloc", ilocHead + (ilocVersion < 2 ? u16be(keptCount) : u32be(keptCount)) + keptEntries)
            case "iprp":
                var body: [UInt8] = []
                for sub in try boxes(d, child.payload) {
                    guard sub.type == "ipma" else { body += d[sub.start..<sub.end]; continue }
                    var q = sub.payload.lowerBound
                    let version = try readUInt(d, &q, 1, limit: sub.end); try skip(&q, 2, sub.end)
                    let flags = try readUInt(d, &q, 1, limit: sub.end)
                    let n = try readUInt(d, &q, 4, limit: sub.end)
                    var entries: [UInt8] = []
                    var kept = 0
                    for _ in 0..<n {
                        let s = q
                        let id = try readUInt(d, &q, version < 1 ? 2 : 4, limit: sub.end)
                        let assoc = try readUInt(d, &q, 1, limit: sub.end)
                        try skip(&q, assoc * ((flags & 1) != 0 ? 2 : 1), sub.end)
                        guard q <= sub.end else { throw corrupt }
                        if !dropped.contains(id) { entries += d[s..<q]; kept += 1 }
                    }
                    body += makeBox("ipma", Array(d[sub.payload.lowerBound..<(sub.payload.lowerBound + 4)]) + u32be(kept) + entries)
                }
                newChildren += makeBox("iprp", body)
            default:
                newChildren += d[child.start..<child.end]
            }
        }
        let newMeta = makeBox("meta", Array(d[meta.payload.lowerBound..<(meta.payload.lowerBound + 4)]) + newChildren)
        let saved = (meta.end - meta.start) - newMeta.count
        guard saved >= 8 else { throw corrupt }
        return Array(d[0..<meta.start]) + newMeta + makeBox("free", [UInt8](repeating: 0, count: saved - 8)) + Array(d[meta.end...])
    }

    // MARK: - Security scan

    static let signatures: [([UInt8], String)] = [
        ([0x50, 0x4B, 0x03, 0x04], "ملف مضغوط ZIP"),
        ([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], "ملف مضغوط RAR"),
        ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], "ملف مضغوط 7z"),
        ([0x4D, 0x5A, 0x90, 0x00], "برنامج ويندوز EXE"),
        ([0x7F, 0x45, 0x4C, 0x46], "برنامج لينكس ELF"),
        ([0xCF, 0xFA, 0xED, 0xFE], "برنامج ماك Mach-O"),
        ([0xCA, 0xFE, 0xBA, 0xBE], "برنامج ماك/جافا"),
        (ascii("%PDF-"), "ملف PDF"),
        (ascii("<script"), "كود JavaScript"),
        (ascii("javascript:"), "كود JavaScript"),
        (ascii("<?php"), "كود PHP"),
        (ascii("<iframe"), "كود HTML"),
        (ascii("#!/bin/"), "سكربت shell"),
        (ascii("powershell"), "أوامر PowerShell"),
        (ascii("eval("), "كود قابل للتنفيذ"),
        (ascii("base64_decode"), "كود PHP مشفّر"),
        (ascii("cmd.exe"), "أوامر ويندوز"),
    ]

    /// strongOnly: use only signatures of 6+ bytes — safe to run over compressed pixel data
    /// (short 4-byte signatures could match random image data by chance).
    static func scan(_ bytes: [UInt8], strongOnly: Bool = false) -> [String] {
        guard !bytes.isEmpty else { return [] }
        let lower = lowercased(bytes)
        var found: [String] = []
        for (sig, name) in signatures where !found.contains(name) && (!strongOnly || sig.count >= 6) {
            if find(lower, lowercased(sig)) { found.append(name) }
        }
        return found
    }

    /// 100 MP covers every phone and pro camera (≈ 400 MB to edit); beyond that is a decode bomb.
    nonisolated(unsafe) static var maxPixels = 100_000_000
    /// Largest file accepted. The app allows more than the Share Extension / Siri (tighter memory).
    nonisolated(unsafe) static var maxInputBytes = 200_000_000

    static func checkDimensions(_ w: Int, _ h: Int) throws {
        guard w > 0, h > 0 else { throw noImage }
        if max(w, h) > 40_000 || w * h > maxPixels {
            throw CleanFailure("أبعاد غير طبيعية \(w)x\(h) (احتمال صورة مفخخة) — تم رفضها")
        }
    }

    // MARK: - EXIF helpers

    static func exifOrientation(_ t: [UInt8]) -> Int {
        guard t.count >= 8 else { return 1 }
        let little = t[0] == 0x49
        func u16(_ i: Int) -> Int? {
            guard i >= 0, i + 2 <= t.count else { return nil }
            return little ? Int(t[i]) | Int(t[i + 1]) << 8 : Int(t[i]) << 8 | Int(t[i + 1])
        }
        func u32(_ i: Int) -> Int? {
            guard i >= 0, i + 4 <= t.count else { return nil }
            return little
                ? Int(t[i]) | Int(t[i + 1]) << 8 | Int(t[i + 2]) << 16 | Int(t[i + 3]) << 24
                : Int(t[i]) << 24 | Int(t[i + 1]) << 16 | Int(t[i + 2]) << 8 | Int(t[i + 3])
        }
        guard let off = u32(4), let count = u16(off) else { return 1 }
        for k in 0..<min(count, 512) {
            let p = off + 2 + 12 * k
            guard let tag = u16(p) else { break }
            if tag == 0x0112, let v = u16(p + 8) { return (1...8).contains(v) ? v : 1 }
        }
        return 1
    }

    /// A TIFF block containing ONLY the Orientation tag.
    static func minimalExif(_ o: Int) -> [UInt8] {
        var t: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A]   // "MM" big-endian TIFF
        t.append(contentsOf: u32be(8))               // IFD offset
        t.append(contentsOf: u16be(1))               // 1 entry
        t.append(contentsOf: u16be(0x0112))          // Orientation
        t.append(contentsOf: u16be(3))               // SHORT
        t.append(contentsOf: u32be(1))               // count
        t.append(contentsOf: u16be(o))
        t.append(contentsOf: u16be(0))
        t.append(contentsOf: u32be(0))               // no next IFD
        return t
    }

    // MARK: - Byte helpers

    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    static func has(_ b: [UInt8], _ at: Int, _ p: [UInt8]) -> Bool {
        guard at >= 0, b.count >= at + p.count else { return false }
        for k in 0..<p.count where b[at + k] != p[k] { return false }
        return true
    }

    static func lowercased(_ b: [UInt8]) -> [UInt8] {
        b.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }
    }

    static func find(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        return Data(hay).range(of: Data(needle)) != nil
    }

    static func be16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }
    static func be32(_ d: [UInt8], _ i: Int) -> Int {
        Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
    }
    static func le16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
    static func le24(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 }
    static func le32(_ d: [UInt8], _ i: Int) -> Int {
        Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
    }

    static func u16be(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func u32be(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    static func u32le(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Decompressed body of a zTXt / compressed iTXt chunk (empty when not compressed or invalid).
    static func inflatedText(_ type: String, _ body: [UInt8]) -> [UInt8] {
        guard let nul = body.firstIndex(of: 0) else { return [] }
        var start = nul + 1
        if type == "iTXt" {
            guard start + 2 <= body.count, body[start] == 1 else { return [] }   // compression flag
            start += 2
            for _ in 0..<2 {                                                     // language, translated keyword
                guard let z = body[start...].firstIndex(of: 0) else { return [] }
                start = z + 1
            }
        } else {
            start += 1                                                           // compression method
        }
        guard start + 2 < body.count else { return [] }
        // zlib stream: skip the 2-byte header; the Compression framework's ZLIB is raw DEFLATE.
        return inflateBounded(Array(body[(start + 2)...]), limit: maxInflate)
    }

    /// Text chunks are scanned after decompression, but never more than this (zip-bomb guard).
    static let maxInflate = 2_000_000

    /// Raw-DEFLATE decompression that STOPS at `limit` output bytes, so a tiny chunk can never
    /// expand into gigabytes of memory.
    static func inflateBounded(_ input: [UInt8], limit: Int) -> [UInt8] {
        guard !input.isEmpty else { return [] }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return [] }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var out: [UInt8] = []
        return input.withUnsafeBufferPointer { src -> [UInt8] in
            guard let base = src.baseAddress else { return [] }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = src.count
            while out.count < limit {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 { out.append(contentsOf: UnsafeBufferPointer(start: dst, count: min(produced, limit - out.count))) }
                if status != COMPRESSION_STATUS_OK || produced == 0 { break }
            }
            return out
        }
    }

    static func sizeText(_ n: Int) -> String {
        n >= 1024 ? String(format: "%.1f كيلوبايت", Double(n) / 1024) : "\(n) بايت"
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
