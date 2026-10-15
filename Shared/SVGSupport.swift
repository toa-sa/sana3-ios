//
//  SVGSupport.swift
//  Image Cleaner — TOA
//
//  1. SVGSanitizer — accepts SVG safely. The file is parsed and REBUILT from an allow-list
//     (the approach of DOMPurify / svg-sanitizer): only drawing elements and presentation
//     attributes survive. Scripts, event handlers, foreignObject, external links, entities
//     (XXE), metadata and editor data are dropped.
//  2. SVGRaster — draws a sanitized SVG to pixels with WebKit (as an <img>, so scripts can
//     never run even if one slipped through), for previews and PNG/JPG/HEIC export.
//  3. Vectorizer — turns logos / flat graphics into a real SVG (colour layers traced with
//     Apple Vision contours).
//

import Foundation
import CoreGraphics
import CoreImage
import Vision
#if canImport(WebKit)
import WebKit
#endif

// MARK: - Sanitizer

enum SVGSanitizer {

    static let elements: Set<String> = [
        "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "textpath", "defs", "lineargradient", "radialgradient", "stop",
        "clippath", "mask", "pattern", "symbol", "use", "marker", "style",
        "fegaussianblur", "filter", "feoffset", "feblend", "fecolormatrix", "fecomposite",
        "feflood", "femerge", "femergenode", "femorphology", "fedropshadow",
    ]

    static let attributes: Set<String> = [
        "id", "class", "style", "transform", "viewbox", "width", "height", "x", "y", "x1", "y1", "x2", "y2",
        "cx", "cy", "r", "rx", "ry", "d", "points", "fill", "fill-opacity", "fill-rule", "stroke",
        "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
        "stroke-dasharray", "stroke-dashoffset", "opacity", "offset", "stop-color", "stop-opacity",
        "gradientunits", "gradienttransform", "spreadmethod", "fx", "fy", "fr", "clip-path", "clip-rule",
        "mask", "maskunits", "maskcontentunits", "patternunits", "patterncontentunits", "patterntransform",
        "preserveaspectratio", "font-family", "font-size", "font-weight", "font-style", "text-anchor",
        "dominant-baseline", "letter-spacing", "word-spacing", "dx", "dy", "rotate", "textlength",
        "lengthadjust", "visibility", "display", "color", "href", "xlink:href", "markerwidth",
        "markerheight", "refx", "refy", "orient", "markerunits", "marker-start", "marker-mid", "marker-end",
        "filter", "stddeviation", "in", "in2", "result", "mode", "values", "type", "operator",
        "k1", "k2", "k3", "k4", "flood-color", "flood-opacity", "radius", "filterunits",
        "primitiveunits", "xmlns", "xmlns:xlink", "version", "xml:space", "direction", "writing-mode",
        "mix-blend-mode", "paint-order", "vector-effect", "shape-rendering", "image-rendering",
    ]

    struct Result {
        let data: Data
        let warnings: [String]
        let width: Double
        let height: Double
    }

    static func clean(_ input: Data) throws -> Result {
        guard input.count < 20_000_000 else { throw CleanFailure("ملف SVG كبير جداً") }
        let delegate = Builder()
        let text = String(decoding: input, as: UTF8.self)
        try checkEntities(text)
        if text.range(of: "<!entity", options: .caseInsensitive) != nil { delegate.sawEntity = true }
        let parser = XMLParser(data: input)
        parser.shouldResolveExternalEntities = false       // no XXE
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else {
            throw CleanFailure("ملف SVG تالف أو مو رسمة صالحة")
        }
        if delegate.sawEntity { delegate.dropped.insert("تعريفات خارجية (Entities)") }
        guard delegate.useCount <= 500, let drawn = delegate.expandedUseCount(), drawn <= 20_000 else {
            throw CleanFailure("ملف SVG فيه تكرار مبالغ فيه (<use>) — تم رفضه")
        }
        guard delegate.drawingCount > 0 else {
            throw CleanFailure("ملف SVG ما فيه رسمة" + (delegate.dropped.contains("سكربت") ? " — فيه سكربت فقط (مشبوه) وتم رفضه" : ""))
        }
        var warnings: [String] = []
        let danger = delegate.dropped.intersection(["سكربت", "أحداث JavaScript", "روابط خارجية", "محتوى HTML (foreignObject)", "تعريفات خارجية (Entities)"])
        if !danger.isEmpty {
            warnings.append("محتوى مشبوه في SVG: \(danger.sorted().joined(separator: "، ")) — تمت إزالته")
        }
        let benign = delegate.dropped.subtracting(danger)
        if !benign.isEmpty {
            warnings.append("انشال من SVG: \(benign.sorted().joined(separator: "، "))")
        }
        let out = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + delegate.output).utf8)
        let w = delegate.width ?? delegate.viewBox?.2 ?? 512
        let h = delegate.height ?? delegate.viewBox?.3 ?? 512
        guard w > 0, h > 0, w <= 40_000, h <= 40_000 else {
            throw CleanFailure("أبعاد SVG غير طبيعية — تم رفضه")
        }
        return Result(data: out, warnings: warnings, width: w, height: h)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var output = ""
        var dropped = Set<String>()
        var sawRoot = false
        var drawingCount = 0
        var useCount = 0
        private var styleBuffer = ""
        var sawEntity = false
        var width: Double?
        var height: Double?
        var viewBox: (Double, Double, Double, Double)?
        private var skipDepth = 0            // > 0 while inside a removed element
        private var inStyle = false
        private var depth = 0
        private var transparent: [Int] = []
        // <use> can point at a group that itself holds <use>s: 10 uses × 8 levels = 100 million shapes.
        private var openIDs: [(depth: Int, id: String)] = []
        private var refs: [String: [String]] = [:]     // id -> the ids its <use>s point at
        private var useTargets: [String] = []

        /// How many shapes the <use>s really draw once expanded; nil when they loop back on themselves.
        func expandedUseCount() -> Int? {
            var memo: [String: Int] = [:], visiting = Set<String>()
            func cost(_ id: String) -> Int? {
                if let c = memo[id] { return c }
                guard visiting.insert(id).inserted else { return nil }           // a loop
                var total = 1
                for r in refs[id] ?? [] {
                    guard let c = cost(r) else { return nil }
                    total = min(total + c, 1_000_000)
                }
                visiting.remove(id); memo[id] = total
                return total
            }
            var total = 0
            for t in useTargets {
                guard let c = cost(t) else { return nil }
                total = min(total + c, 1_000_000)
            }
            return total
        }

        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { sawEntity = true }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { sawEntity = true }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { sawEntity = true }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { sawEntity = true; return nil }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            depth += 1
            let local = (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
            if skipDepth > 0 { skipDepth += 1; return }
            if depth == 1 {
                guard local == "svg" else { skipDepth = 1; return }
                sawRoot = true
            }
            if local == "a" || local == "switch" {             // links: keep the drawing, drop the link
                if attributes.keys.contains(where: { $0.lowercased().hasSuffix("href") }) { dropped.insert("روابط خارجية") }
                transparent.append(depth)
                return
            }
            guard SVGSanitizer.elements.contains(local), !name.contains(":") || name.hasPrefix("svg:") else {
                switch local {
                case "script": dropped.insert("سكربت")
                case "foreignobject": dropped.insert("محتوى HTML (foreignObject)")
                case "image", "feimage": dropped.insert("روابط خارجية")
                case "metadata", "title", "desc": dropped.insert("بيانات وصفية")
                default: dropped.insert("عناصر برامج التصميم")
                }
                skipDepth = 1
                return
            }
            var attrs: [(String, String)] = []
            for (k, v) in attributes.sorted(by: { $0.key < $1.key }) {
                let key = k.lowercased()
                if key.hasPrefix("on") { dropped.insert("أحداث JavaScript"); continue }
                if key.hasPrefix("xmlns:") { continue }                 // re-added below with the fixed value
                guard SVGSanitizer.attributes.contains(key) else {
                    if key.contains(":") { dropped.insert("عناصر برامج التصميم") }
                    continue
                }
                if key == "href" || key == "xlink:href" {
                    guard v.hasPrefix("#") else { dropped.insert("روابط خارجية"); continue }
                }
                if key == "xmlns" && v != "http://www.w3.org/2000/svg" { continue }
                if key == "style" {
                    let (css, removed) = SVGSanitizer.cleanCSS(v)
                    if removed { dropped.insert("روابط خارجية") }
                    attrs.append((k, css)); continue
                }
                if !SVGSanitizer.safeValue(v) { dropped.insert("روابط خارجية"); continue }
                attrs.append((k, v))
            }
            if depth == 1 {
                width = SVGSanitizer.number(attributes["width"])
                height = SVGSanitizer.number(attributes["height"])
                if let vb = attributes["viewBox"] ?? attributes["viewbox"] {
                    let n = vb.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                    if n.count == 4 { viewBox = (n[0], n[1], n[2], n[3]) }
                }
                if !attrs.contains(where: { $0.0 == "xmlns" }) { attrs.insert(("xmlns", "http://www.w3.org/2000/svg"), at: 0) }
                if attrs.contains(where: { $0.0 == "xlink:href" || $0.0 == "href" }) || true {
                    if !attrs.contains(where: { $0.0 == "xmlns:xlink" }) { attrs.append(("xmlns:xlink", "http://www.w3.org/1999/xlink")) }
                }
            }
            inStyle = local == "style"
            styleBuffer = ""
            if local == "use" {
                useCount += 1
                if let href = attrs.first(where: { $0.0.lowercased().hasSuffix("href") })?.1, href.hasPrefix("#") {
                    let target = String(href.dropFirst())
                    useTargets.append(target)
                    for open in openIDs { refs[open.id, default: []].append(target) }
                }
            }
            if let id = attributes["id"] { openIDs.append((depth, id)) }
            if ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "use"].contains(local) { drawingCount += 1 }
            output += "<\(local == "svg" ? "svg" : name.replacingOccurrences(of: "svg:", with: ""))"
            for (k, v) in attrs { output += " \(k)=\"\(SVGSanitizer.escape(v))\"" }
            output += ">"
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { depth -= 1 }
            if skipDepth > 0 { skipDepth -= 1; return }
            if transparent.last == depth { transparent.removeLast(); return }
            if openIDs.last?.depth == depth { openIDs.removeLast() }
            if inStyle {
                // The whole stylesheet at once: "ur&#108;(" or CDATA splits can't hide a url( any more.
                let (css, removed) = SVGSanitizer.cleanCSS(styleBuffer)
                if removed { dropped.insert("روابط خارجية") }
                output += SVGSanitizer.escape(css)
                styleBuffer = ""
            }
            inStyle = false
            output += "</\(name.replacingOccurrences(of: "svg:", with: ""))>"
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            if inStyle { styleBuffer += string; return }
            output += SVGSanitizer.escape(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard skipDepth == 0, inStyle, let s = String(data: CDATABlock, encoding: .utf8) else { return }
            styleBuffer += s
        }

        func parser(_ parser: XMLParser, foundComment comment: String) { dropped.insert("تعليقات") }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {}
    }

    /// No scripts or external resources inside attribute values / CSS.
    static func safeValue(_ v: String) -> Bool {
        if v.contains("\\") || v.contains("/*") { return false }      // CSS escapes / comments can hide url(
        let s = v.lowercased().replacingOccurrences(of: " ", with: "")
        if s.contains("javascript:") || s.contains("vbscript:") || s.contains("data:") || s.contains("expression(")
            || s.contains("image-set(") || s.contains("cross-fade(") || s.contains("element(") || s.contains("@import") { return false }
        var rest = Substring(s)
        while let r = rest.range(of: "url(") {
            let after = rest[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if !after.hasPrefix("#") { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }

    /// Removes @import, external url(...), scripts and expressions from CSS; keeps everything else.
    static func cleanCSS(_ css: String) -> (String, Bool) {
        if css.contains("\\") || css.contains("/*") { return ("", true) }   // escapes / comments: too risky, drop it all
        // A web address, or a stylesheet that opens a block / bracket / quote it never closes
        // (a url( split across two <style> tags), has no place in a drawing: drop it all.
        if css.contains("://") || css.contains("//") { return ("", true) }
        let count = { (c: Character) in css.reduce(0) { $1 == c ? $0 + 1 : $0 } }
        if count("{") != count("}") || count("(") != count(")") || count("\"") % 2 != 0 || count("'") % 2 != 0 {
            return ("", true)
        }
        var s = css, removed = false
        let patterns = [
            #"@import[^;]*;?"#,
            #"(?i)@(?!media|keyframes|-webkit-keyframes)[a-z-]+[^;{]*(;|\{[^}]*\})"#,
            #"(?i)(-webkit-)?image-set\([^)]*\)"#,
            #"(?i)cross-fade\([^)]*\)"#,
            #"(?i)element\([^)]*\)"#,
            #"(?i)url\(\s*['"]?\s*data:[^)]*\)"#,
            #"url\(\s*['"]?(?!#)[^)]*\)"#,
            #"(?i)expression\s*\([^)]*\)"#,
            #"(?i)(java|vb)script\s*:"#,
            #"(?i)-moz-binding\s*:[^;]*;?"#,
            #"(?i)behavior\s*:[^;]*;?"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            if re.firstMatch(in: s, range: range) != nil {
                removed = true
                s = re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            }
        }
        return (s, removed)
    }

    /// Illustrator files declare a few plain text entities (namespaces) — those are fine.
    /// External entities (XXE) and entities that reference other entities (billion laughs) are not.
    static func checkEntities(_ text: String) throws {
        guard let re = try? NSRegularExpression(pattern: #"<!ENTITY\s+%?\s*[^\s]+\s+(SYSTEM|PUBLIC|"[^"]*"|'[^']*')"#,
                                                options: [.caseInsensitive]) else { return }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count <= 64 else { throw CleanFailure("ملف SVG فيه تعريفات كثيرة مشبوهة — تم رفضه") }
        for m in matches {
            let kind = ns.substring(with: m.range(at: 1))
            if kind.uppercased() == "SYSTEM" || kind.uppercased() == "PUBLIC" {
                throw CleanFailure("ملف SVG يحاول يقرأ ملفات خارجية (XXE) — تم رفضه")
            }
            if kind.contains("&") || kind.contains("%") || kind.count > 4096 {
                throw CleanFailure("ملف SVG فيه تعريفات متداخلة (قنبلة تكبير) — تم رفضه")
            }
        }
    }

    static func number(_ s: String?) -> Double? {
        guard let s else { return nil }
        let digits = s.prefix { "0123456789.".contains($0) }
        guard let n = Double(digits), n > 0 else { return nil }
        return s.hasSuffix("%") ? nil : n
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Rasterizer (WebKit)

#if canImport(WebKit) && os(iOS)
@MainActor
enum SVGRaster {
    /// Draws the SVG at `maxSide` on its longest edge, transparent background.
    static func render(_ svg: Data, width: Double, height: Double, maxSide: Int = 2048) async -> CGImage? {
        // Lay the page out in points; the snapshot comes back at screen scale (px = pt × scale).
        let screen = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
        let s = Double(maxSide) / max(width, height)
        let wPx = max(1, (width * s).rounded()), hPx = max(1, (height * s).rounded())
        let w = wPx / screen, h = hPx / screen
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()                 // nothing written to disk, no cookies
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: w, height: h), configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;width:100%;height:100%}
        img{display:block;width:100vw;height:100vh;object-fit:contain}</style></head>
        <body><img src="data:image/svg+xml;base64,\(svg.base64EncodedString())"></body></html>
        """
        let loader = Loader()
        web.navigationDelegate = loader
        web.loadHTMLString(html, baseURL: nil)
        // Never wait forever: a hostile drawing can stall or kill the web content process.
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            loader.cancel()
        }
        defer { timeout.cancel() }
        guard await loader.wait() else { web.stopLoading(); return nil }
        try? await Task.sleep(nanoseconds: 120_000_000)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: w, height: h)
        let image: UIImage? = await withCheckedContinuation { c in
            web.takeSnapshot(with: cfg) { img, _ in c.resume(returning: img) }
        }
        return image?.cgImage
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var done: Bool?
        func wait() async -> Bool {
            if let done { return done }
            return await withCheckedContinuation { continuation = $0 }
        }
        private func finish(_ ok: Bool) {
            guard done == nil else { return }
            done = ok
            continuation?.resume(returning: ok)
            continuation = nil
        }
        func cancel() { finish(false) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    }
}
#endif

// MARK: - Vectorizer

enum Vectorizer {

    /// True when the image is a good candidate for tracing (logos, icons, flat graphics).
    static func canTrace(_ image: CGImage) -> Bool {
        let px = RGBAImage(image)
        if ImageTools.hasAlpha(image), px.pixels.enumerated().contains(where: { $0.offset % 4 == 3 && $0.element < 128 }) {
            return true
        }
        return Cutout.detectPlain(px) != nil
    }

    static func trace(_ input: CGImage, maxColors: Int = 8) throws -> Data {
        // Work at a sensible size; coordinates are scaled back to the original size.
        let maxSide = 1200
        let scale = min(1, Double(maxSide) / Double(max(input.width, input.height)))
        let work: CGImage = scale < 1
            ? (try ImageTools.resize(input, to: .scale(scale), mode: .fit, focus: nil))
            : input
        var px = RGBAImage(work)
        let w = px.width, h = px.height, n = w * h

        // Background: transparent pixels, or a plain colour removed like the background tool does.
        var alpha = [Float](repeating: 1, count: n)
        var anyTransparent = false
        for p in 0..<n where px.pixels[p * 4 + 3] < 128 { alpha[p] = 0; anyTransparent = true }
        if !anyTransparent, let plain = Cutout.detectPlain(px) {
            alpha = Cutout.plainAlpha(px, plain)
        }

        // Colour palette (k-means on the visible pixels).
        var samples: [(Float, Float, Float)] = []
        let stride = max(1, n / 60_000)
        var p = 0
        while p < n {
            if alpha[p] >= 0.5 {
                let i = p * 4
                samples.append((Float(px.pixels[i]), Float(px.pixels[i + 1]), Float(px.pixels[i + 2])))
            }
            p += stride
        }
        guard samples.count > 20 else { throw CleanFailure("ما لقيت شكل واضح أحوّله لـ SVG") }
        var centers = kmeans(samples, k: maxColors)
        centers = merge(centers, within: 28)

        // Label every visible pixel with its nearest colour.
        var label = [Int8](repeating: -1, count: n)
        var counts = [Int](repeating: 0, count: centers.count)
        for p in 0..<n where alpha[p] >= 0.5 {
            let i = p * 4
            let c = (Float(px.pixels[i]), Float(px.pixels[i + 1]), Float(px.pixels[i + 2]))
            var best = 0, bd = Float.greatestFiniteMagnitude
            for (k, ctr) in centers.enumerated() {
                let d = (c.0 - ctr.0) * (c.0 - ctr.0) + (c.1 - ctr.1) * (c.1 - ctr.1) + (c.2 - ctr.2) * (c.2 - ctr.2)
                if d < bd { bd = d; best = k }
            }
            label[p] = Int8(best); counts[best] += 1
        }
        px.pixels = []

        let outW = Double(input.width), outH = Double(input.height)
        var body = ""
        // Big areas first, details on top.
        for k in counts.indices.sorted(by: { counts[$0] > counts[$1] }) where counts[k] > n / 4000 {
            guard let mask = maskImage(label, k, w, h) else { continue }
            let d = try contours(mask, outW: outW, outH: outH)
            guard !d.isEmpty else { continue }
            let c = centers[k]
            body += String(format: "<path fill=\"#%02X%02X%02X\" fill-rule=\"evenodd\" d=\"%@\"/>\n",
                           Int(c.0.rounded()), Int(c.1.rounded()), Int(c.2.rounded()), d)
        }
        guard !body.isEmpty else { throw CleanFailure("ما قدرت أحوّل الصورة لـ SVG") }
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(outW))" height="\(Int(outH))" viewBox="0 0 \(Int(outW)) \(Int(outH))">
        \(body)</svg>
        """
        return Data(svg.utf8)
    }

    private static func maskImage(_ label: [Int8], _ k: Int, _ w: Int, _ h: Int) -> CGImage? {
        // Black shape on white (Vision traces dark on light), with a 2 px white border.
        let W = w + 4, H = h + 4
        var buf = [UInt8](repeating: 255, count: W * H)
        for y in 0..<h { for x in 0..<w where label[y * w + x] == Int8(k) { buf[(y + 2) * W + x + 2] = 0 } }
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func contours(_ mask: CGImage, outW: Double, outH: Double) throws -> String {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = true
        request.contrastAdjustment = 1
        request.maximumImageDimension = max(mask.width, mask.height)
        try VNImageRequestHandler(cgImage: mask, options: [:]).perform([request])
        guard let obs = request.results?.first else { return "" }
        // Mask has a 2 px border: map normalized mask coords back to the image.
        let mw = Double(mask.width), mh = Double(mask.height)
        let sx = outW / (mw - 4), sy = outH / (mh - 4)
        var d = ""
        func add(_ contour: VNContour) {
            let simplified = (try? contour.polygonApproximation(epsilon: 0.0008)) ?? contour
            let pts = simplified.normalizedPoints
            guard pts.count >= 3 else { return }
            for (i, pt) in pts.enumerated() {
                let x = (Double(pt.x) * mw - 2) * sx
                let y = ((1 - Double(pt.y)) * mh - 2) * sy
                d += String(format: "%@%.1f %.1f", i == 0 ? "M" : "L", x, y)
            }
            d += "Z"
            for child in contour.childContours { add(child) }
        }
        for c in obs.topLevelContours { add(c) }
        return d
    }

    private static func kmeans(_ s: [(Float, Float, Float)], k: Int) -> [(Float, Float, Float)] {
        // k-means++ style seeding by farthest point, then a few Lloyd iterations.
        var centers = [s[s.count / 2]]
        while centers.count < min(k, s.count) {
            var far = s[0], fd: Float = -1
            for v in s {
                let d = centers.map { dist2(v, $0) }.min()!
                if d > fd { fd = d; far = v }
            }
            if fd < 400 { break }                      // no more distinct colours
            centers.append(far)
        }
        for _ in 0..<8 {
            var sum = [(Float, Float, Float, Float)](repeating: (0, 0, 0, 0), count: centers.count)
            for v in s {
                var best = 0, bd = Float.greatestFiniteMagnitude
                for (i, c) in centers.enumerated() { let d = dist2(v, c); if d < bd { bd = d; best = i } }
                sum[best].0 += v.0; sum[best].1 += v.1; sum[best].2 += v.2; sum[best].3 += 1
            }
            for i in centers.indices where sum[i].3 > 0 {
                centers[i] = (sum[i].0 / sum[i].3, sum[i].1 / sum[i].3, sum[i].2 / sum[i].3)
            }
        }
        return centers
    }

    private static func merge(_ c: [(Float, Float, Float)], within t: Float) -> [(Float, Float, Float)] {
        var out: [(Float, Float, Float)] = []
        for v in c where !out.contains(where: { dist2($0, v) < t * t }) { out.append(v) }
        return out
    }

    private static func dist2(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        let x = a.0 - b.0, y = a.1 - b.1, z = a.2 - b.2
        return x * x + y * y + z * z
    }
}
