//
//  CleanSession.swift
//  Image Cleaner — TOA
//

import SwiftUI
import UIKit
import ImageIO
import Photos

struct CleanInput {
    let data: Data
    /// File name used only to check the extension (e.g. "photo.heic").
    let name: String?
    /// Name shown to the user when cleaning fails.
    let displayName: String
}

struct CleanedItem: Identifiable {
    let id = UUID()
    let displayName: String
    var outputName: String = ""
    var data: Data? = nil
    var fileURL: URL? = nil
    var warnings: [String] = []
    var error: String? = nil
    var thumbnail: UIImage? = nil
    /// What identifying data the original carried (and was removed), for the scan panel.
    var removedInfo: [String] = []

    /// e.g. "JPG · 4032×3024 · 2.4 MB" for the current version.
    var summaryLine: String {
        guard let data else { return "" }
        return CleanSession.describe(data, ext: (outputName as NSString).pathExtension)
    }
    /// SVG only: a PNG drawing of the (clean) SVG, used for previews and as the source for the tools.
    var svgRaster: Data? = nil
    var cleanSVGRaster: Data? = nil
    var isSVG: Bool { (outputName as NSString).pathExtension.lowercased() == "svg" }
    /// What the image tools and previews work on (the pixels).
    var editableData: Data? { isSVG ? svgRaster : data }
    /// The cleaned version (before any tools) — kept so edits can be undone.
    var cleanData: Data? = nil
    var cleanURL: URL? = nil
    var cleanName: String = ""
    var cleanThumbnail: UIImage? = nil
    /// Set when the image tools changed this item.
    var editNote: String? = nil
    var editWarnings: [String] = []
    var lastEditFailed = false
    /// Earlier versions, newest last — "تراجع" steps back one edit at a time.
    var history: [Snapshot] = []

    struct Snapshot {
        let data: Data?
        let fileURL: URL?
        let outputName: String
        let thumbnail: UIImage?
        let svgRaster: Data?
        let editNote: String?
    }

    var snapshot: Snapshot {
        Snapshot(data: data, fileURL: fileURL, outputName: outputName, thumbnail: thumbnail,
                 svgRaster: svgRaster, editNote: editNote)
    }

    var isEdited: Bool { editNote != nil }
}


@MainActor
final class CleanSession: ObservableObject {
    @Published var items: [CleanedItem] = []
    @Published var isWorking = false
    @Published var statusMessage: String? = nil
    /// First image of the latest batch; the main screen shows it.
    @Published var focusID: UUID? = nil
    /// Bumped when something finished (clean, edit, save) — drives haptic feedback.
    @Published var feedbackTick = 0
    /// Bumped when a "clean and share" run finished — the app then opens the share sheet.
    @Published var autoShareURLs: [URL] = []
    private var counter = 0

    var shareURLs: [URL] { items.compactMap(\.fileURL) }

    func process(_ inputs: [CleanInput]) async {
        guard !inputs.isEmpty else { return }
        isWorking = true
        statusMessage = nil
        let stamp = Self.timestamp()
        let firstIndex = counter + 1
        for input in inputs {
            counter += 1
            let index = counter
            var item = await Task.detached(priority: .userInitiated) {
                CleanSession.makeItem(input, index: index, stamp: stamp)
            }.value
            if item.isSVG { await rasterizeSVG(&item) }
            items.append(item)
            if index == firstIndex { focusID = item.id }
        }
        isWorking = false
        statusMessage = summary()
        feedbackTick += 1
    }

    func addFailure(_ name: String, _ message: String) {
        var item = CleanedItem(displayName: name)
        item.error = message
        items.append(item)
        focusID = item.id
    }

    /// Draws a clean SVG once (WebKit, scripts disabled) for the thumbnail, previews and tools.
    func rasterizeSVG(_ item: inout CleanedItem) async {
        #if os(iOS)
        guard let data = item.data, let svg = try? SVGSanitizer.clean(data),
              let image = await SVGRaster.render(svg.data, width: svg.width, height: svg.height),
              let png = try? ImageTools.encode(image, as: .png, quality: 1) else {
            item.warnings.append("ما قدرت أعرض رسمة SVG — الملف النظيف جاهز للمشاركة")
            return
        }
        item.svgRaster = png
        item.cleanSVGRaster = png
        item.thumbnail = CleanSession.thumbnail(png)
        item.cleanThumbnail = item.thumbnail
        #endif
    }

    func remove(_ id: UUID) {
        guard let k = items.firstIndex(where: { $0.id == id }) else { return }
        for url in [items[k].fileURL, items[k].cleanURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        items.remove(at: k)
        focusID = items.isEmpty ? nil : items[min(k, items.count - 1)].id
    }

    /// Cleans, then hands the clean files to the share sheet (one tap from picking to sharing).
    func processAndShare(_ inputs: [CleanInput]) async {
        let before = Set(items.map(\.id))
        await process(inputs)
        autoShareURLs = items.filter { !before.contains($0.id) }.compactMap(\.fileURL)
    }

    func clear() {
        for item in items {
            for url in [item.fileURL, item.cleanURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        }
        items.removeAll()
        statusMessage = nil
    }

    func saveAllToPhotos() async {
        await saveToPhotos(items.map(\.id))
    }

    func saveToPhotos(_ ids: [UUID]) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            statusMessage = "ما فيه صلاحية للحفظ في الصور — فعّلها من الإعدادات"
            return
        }
        var saved = 0, failed = 0
        for item in items where ids.contains(item.id) {
            // The Photos library has no SVG support: an SVG is saved as its PNG drawing.
            guard let data = item.isSVG ? item.svgRaster : item.data else { continue }
            let name = item.isSVG ? (item.outputName as NSString).deletingPathExtension + ".png" : item.outputName
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    request.addResource(with: .photo, data: data, options: options)
                }
                saved += 1
            } catch {
                failed += 1
            }
        }
        statusMessage = failed == 0
            ? "✅ انحفظت \(saved) صورة في الصور"
            : "انحفظت \(saved) — وتعذّر حفظ \(failed) (جرّب زر المشاركة ← حفظ في الملفات)"
        feedbackTick += 1
    }

    // MARK: - Image tools

    /// Applies a tool to `primary` and, when given, to other images too (they use automatic focus / all subjects).
    func applyTools(_ options: EditOptions, primary: UUID, others: [UUID] = []) async {
        guard !options.isEmpty else { return }
        isWorking = true
        statusMessage = nil
        var edited = 0, failed = 0
        for id in [primary] + others.filter({ $0 != primary }) {
            guard let item = items.first(where: { $0.id == id }), item.data != nil else { continue }
            var o = options
            if id != primary {
                o.focus = nil
                o.excludedPoints = []
            }
            let updated = await Task.detached(priority: .userInitiated) {
                CleanSession.makeEdited(item, o)
            }.value
            var final = updated
            if final.isSVG && final.svgRaster == nil && !final.lastEditFailed {
                let keepClean = final.cleanSVGRaster
                await rasterizeSVG(&final)
                final.cleanSVGRaster = keepClean
                final.cleanThumbnail = updated.cleanThumbnail
            }
            if let k = items.firstIndex(where: { $0.id == id }) { items[k] = final }
            if final.lastEditFailed { failed += 1 } else { edited += 1 }
        }
        isWorking = false
        statusMessage = failed == 0 ? "✏️ تم تعديل \(edited) صورة" : "✏️ تم تعديل \(edited) — وتعذّر \(failed)"
        feedbackTick += 1
    }

    /// Steps back one edit (to the clean version after the last one).
    func undoLastEdit(_ id: UUID) {
        guard let k = items.firstIndex(where: { $0.id == id }), let previous = items[k].history.popLast() else { return }
        if let url = items[k].fileURL, url != items[k].cleanURL, url != previous.fileURL,
           !items[k].history.contains(where: { $0.fileURL == url }) {
            try? FileManager.default.removeItem(at: url)
        }
        items[k].data = previous.data
        items[k].fileURL = previous.fileURL
        items[k].outputName = previous.outputName
        items[k].thumbnail = previous.thumbnail
        items[k].svgRaster = previous.svgRaster
        items[k].editNote = previous.editNote
        items[k].editWarnings = []
        items[k].lastEditFailed = false
        feedbackTick += 1
    }

    /// Back to the clean version, dropping every edit.
    func revertTools(_ id: UUID) {
        guard let k = items.firstIndex(where: { $0.id == id }), items[k].isEdited else { return }
        if let url = items[k].fileURL, url != items[k].cleanURL { try? FileManager.default.removeItem(at: url) }
        items[k].data = items[k].cleanData
        items[k].svgRaster = items[k].cleanSVGRaster
        items[k].fileURL = items[k].cleanURL
        items[k].outputName = items[k].cleanName
        items[k].thumbnail = items[k].cleanThumbnail
        items[k].editNote = nil
        items[k].editWarnings = []
        items[k].lastEditFailed = false
        for old in items[k].history.compactMap(\.fileURL) where old != items[k].cleanURL {
            try? FileManager.default.removeItem(at: old)
        }
        items[k].history = []
        feedbackTick += 1
    }

    nonisolated static func makeEdited(_ item: CleanedItem, _ options: EditOptions) -> CleanedItem {
        var item = item
        guard let current = item.editableData else { return item }
        let currentExt = item.isSVG ? "png" : (item.outputName as NSString).pathExtension
        do {
            // Tools stack: each one works on the latest version (e.g. remove background, then resize).
            let result = try autoreleasepool {
                try ImageTools.apply(options, to: current, currentExtension: currentExt)
            }
            // Edited copies live in their own folder, so the clean file is never overwritten.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Edited", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Each edit gets its own file so earlier steps stay available for "تراجع";
            // the shared file name stays neutral (IMG_…_001.ext).
            let step = item.history.count + 1
            let stepDir = dir.appendingPathComponent("\(item.id.uuidString)-\(step)", isDirectory: true)
            try FileManager.default.createDirectory(at: stepDir, withIntermediateDirectories: true)
            let name = (item.cleanName as NSString).deletingPathExtension + "." + result.fileExtension
            let url = stepDir.appendingPathComponent(name)
            try result.data.write(to: url, options: [.atomic, .completeFileProtection])
            item.history.append(item.snapshot)
            item.data = result.data
            item.fileURL = url
            item.outputName = name
            item.svgRaster = nil                                   // traced SVG: drawn again on the main actor
            item.thumbnail = result.fileExtension == "svg" ? item.thumbnail : thumbnail(result.data)
            if item.editNote != result.note {           // same edit twice -> show it once
                item.editNote = [item.editNote, result.note].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "، ")
            }
            item.editWarnings = result.warnings
            item.lastEditFailed = false
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            item.editWarnings = ["ما تم التعديل: \(message)"]
            item.lastEditFailed = true
        }
        return item
    }

    private func summary() -> String {
        let ok = items.filter { $0.error == nil }
        let warned = ok.filter { !$0.warnings.isEmpty }.count
        let failed = items.count - ok.count
        var parts = ["تم تنظيف \(ok.count) صورة"]
        if warned > 0 { parts.append("⚠️ \(warned) فيها تنبيهات") }
        if failed > 0 { parts.append("⛔️ رُفض \(failed)") }
        if warned == 0 && failed == 0 { parts.append("✅ ما فيه أي شي مشبوه") }
        return parts.joined(separator: " — ")
    }

    // MARK: - Work (runs off the main thread)

    nonisolated static func makeItem(_ input: CleanInput, index: Int, stamp: String) -> CleanedItem {
        var item = CleanedItem(displayName: input.displayName)
        do {
            let result = try CleanerCore.clean(input.data, originalName: input.name)
            let name = String(format: "IMG_%@_%03d.%@", stamp, index, result.fileExtension)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Cleaned", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try result.data.write(to: url, options: [.atomic, .completeFileProtection])
            item.outputName = name
            item.data = result.data
            item.fileURL = url
            item.warnings = result.warnings
            item.thumbnail = thumbnail(result.data)
            item.cleanData = result.data
            item.cleanURL = url
            item.cleanName = name
            item.cleanThumbnail = item.thumbnail
            item.removedInfo = removedInfo(input.data)
        } catch {
            item.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return item
    }

    /// Lists the identifying data found in the ORIGINAL file (all of it is gone from the clean copy).
    nonisolated static func removedInfo(_ data: Data) -> [String] {
        var found: [String] = []
        let lower = Data(data.prefix(4_000_000).map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 })
        func has(_ s: String) -> Bool { lower.range(of: Data(s.utf8)) != nil }
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if p[kCGImagePropertyGPSDictionary] != nil { found.append("الموقع (GPS)") }
            let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            if tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil
                || exif[kCGImagePropertyExifLensModel] != nil || p[kCGImagePropertyMakerAppleDictionary] != nil {
                found.append("نوع الجهاز والعدسة")
            }
            if exif[kCGImagePropertyExifDateTimeOriginal] != nil || tiff[kCGImagePropertyTIFFDateTime] != nil {
                found.append("تاريخ ووقت التصوير")
            }
            if tiff[kCGImagePropertyTIFFSoftware] != nil { found.append("البرنامج المستخدم") }
            if p[kCGImagePropertyIPTCDictionary] != nil { found.append("بيانات IPTC") }
        }
        if has("<x:xmpmeta") || has("http://ns.adobe.com/xap/1.0/") { found.append("بيانات XMP") }
        if has("c2pa") || has("jumbf") || has("cabx") { found.append("توقيع Content Credentials (C2PA)") }
        if has("parameters") || has("prompt") || has("comfyui") || has("midjourney")
            || has("stable diffusion") || has("dall-e") || has("dall·e") {
            found.append("وسوم أو أوامر الذكاء الاصطناعي")
        }
        return found
    }

    nonisolated static func describe(_ data: Data, ext: String) -> String {
        var parts = [ext.uppercased() == "JPEG" ? "JPG" : ext.uppercased()]
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let (dw, dh) = (5...8).contains(o) ? (h, w) : (w, h)          // as it is displayed
            parts.append("\u{2066}\(dw)×\(dh)\u{2069}")
        }
        let f = ByteCountFormatter(); f.countStyle = .file
        parts.append(f.string(fromByteCount: Int64(data.count)))
        return parts.joined(separator: " · ")
    }

    /// Clean / edited copies only live while you use them: removed on launch and when the
    /// Share Extension closes, and written with complete file protection (encrypted while locked).
    nonisolated static func removeTemporaryFiles() {
        let tmp = FileManager.default.temporaryDirectory
        for name in ["Cleaned", "Edited"] {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name, isDirectory: true))
        }
    }

    nonisolated static func thumbnail(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    nonisolated static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
