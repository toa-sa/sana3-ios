//
//  ToolScreens.swift
//  Image Cleaner — TOA
//
//  One screen per tool, each with a live preview: background, size, format.
//

import SwiftUI
import UIKit

// MARK: - Live preview model

@MainActor
final class ToolPreview: ObservableObject {
    let source: CGImage?
    @Published var image: CGImage?
    @Published var message: String?
    @Published var working = false
    @Published var analysis: SubjectAnalysis?
    /// The image has a plain (one-colour) background: removed by colour, no Vision needed.
    @Published var plainBackground = false
    private var task: Task<Void, Never>?

    init(data: Data?) {
        source = data.flatMap { try? ImageTools.decode($0, maxSide: 1400) }
        image = source
    }

    /// Finds the people / objects once (background tool).
    func analyze() async {
        guard analysis == nil, let src = source else { return }
        working = true
        plainBackground = await Task.detached(priority: .userInitiated) {
            let px = RGBAImage(src)
            return Cutout.existingAlpha(px) != nil || Cutout.detectPlain(px) != nil
        }.value
        do {
            analysis = try await Task.detached(priority: .userInitiated) { try SubjectAnalysis(image: src) }.value
        } catch {
            if !plainBackground { message = errorText(error) }      // a plain background works without Vision
        }
        working = false
    }

    func render(_ options: EditOptions) {
        task?.cancel()
        guard let src = source else { return }
        if options.removeBackground && analysis == nil && !plainBackground { return }
        let a = analysis
        task = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            working = true
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
                Result { try ImageTools.process(src, options, analysis: a).image }
            }.value
            if Task.isCancelled { return }
            working = false
            switch result {
            case .success(let img): image = img; message = nil
            case .failure(let e): message = errorText(e)
            }
        }
    }
}

func errorText(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

// MARK: - Shared pieces

struct Checkerboard: View {
    var cell: CGFloat = 10
    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)),
                             with: .color(Color(white: 0.86)))
                }
            }
        }
        .background(Color.white)
    }
}

/// Shows an image aspect-fit; reports taps in normalized image coordinates.
struct PreviewCanvas<Overlay: View>: View {
    @Environment(\.layoutDirection) private var direction
    let image: CGImage?
    var checker = false
    var onTap: ((CGPoint) -> Void)? = nil
    @ViewBuilder var overlay: (CGRect) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let rect = fitted(in: geo.size)
            let x = PhysicalX(direction: direction, width: geo.size.width)
            let origin = geo.frame(in: .global).origin
            ZStack {
                if checker {
                    Checkerboard()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: x(rect.midX), y: rect.midY)
                }
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: x(rect.midX), y: rect.midY)
                }
                overlay(rect)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onEnded { value in  // a tap
                // Screen coordinates are never mirrored: measure from the canvas' left edge.
                let p = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)
                guard let onTap, rect.contains(p),
                      hypot(value.translation.width, value.translation.height) < 10 else { return }
                onTap(CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height))
            })
        }
        // Pixels are placed through PhysicalX, so no layout-direction override is needed.
    }

    private func fitted(in size: CGSize) -> CGRect {
        guard let image, image.width > 0, image.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let s = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// One tool inside the editor: live preview on top, settings below, Cancel / Apply at the bottom.
struct ToolScaffold<Controls: View, Preview: View>: View {
    let title: String
    let canApply: Bool
    let onApply: () -> Void
    let onClose: () -> Void
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        VStack(spacing: 0) {
            preview()
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surfaceSunken)
                .layoutPriority(1)
            controlsContainer
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Text("إلغاء").frame(maxWidth: .infinity)
                }
                .buttonStyle(TOAButtonStyle(kind: .secondary))
                Button {
                    onApply()
                    onClose()
                } label: {
                    Text("تطبيق \(title)").frame(maxWidth: .infinity)
                }
                .buttonStyle(TOAButtonStyle(kind: .primary))
                .disabled(!canApply)
            }
            .padding(12)
            .background(Theme.surfaceRaised)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// Own settings cards instead of a system Form: on iOS 16 the Form (a UIKit list) in this
    /// screen draws its text mirrored. A plain ScrollView renders correctly on every version.
    private var controlsContainer: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { controls() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(width: geo.size.width)          // a wide row wraps or shrinks, never widens the tool
            }
        }
        .background(Theme.surface)
        .frame(minHeight: 220, idealHeight: 300, maxHeight: 340)
    }
}

/// TOA buttons (toa-ui.css): 44pt high, radius 10, Cairo SemiBold.
struct TOAButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.toa(.callout, .semibold))
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .foregroundStyle(kind == .primary ? Color.white : Theme.green)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(kind == .primary ? Theme.green : Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(kind == .primary ? Color.clear : Color(red: 201 / 255, green: 209 / 255, blue: 204 / 255), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

struct StatusPill: View {
    let working: Bool
    let message: String?
    let hint: String?

    var body: some View {
        Group {
            if working {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("جاري المعالجة…") }
            } else if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            } else if let hint {
                Text(hint)
            }
        }
        .font(.toa(.caption, .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
    }
}

@MainActor private func otherIDs(_ session: CleanSession, except id: UUID) -> [UUID] {
    session.items.filter { $0.data != nil && $0.id != id }.map(\.id)
}

// MARK: - Background

struct BackgroundToolView: View {
    @ObservedObject var session: CleanSession
    let itemID: UUID
    let onClose: () -> Void
    @StateObject private var preview: ToolPreview

    enum Fill: Hashable { case transparent, blur, color }

    @State private var fill: Fill = .transparent
    @State private var blur = 0.5
    @State private var color: Color = .white
    @State private var softness = 0.0
    @State private var cropToSubject = false
    @State private var removeEnclosed = false
    @State private var margin = 0.08
    @State private var excluded: Set<Int> = []
    @State private var applyToAll = false

    init(session: CleanSession, itemID: UUID, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.session = session
        self.itemID = itemID
        _preview = StateObject(wrappedValue: ToolPreview(data: session.items.first { $0.id == itemID }?.editableData))
    }

    private static let swatches: [Color] = [.white, .black, Theme.green, Theme.gold, Theme.cream]

    private var options: EditOptions {
        var o = EditOptions()
        o.removeBackground = true
        switch fill {
        case .transparent: o.background = .transparent
        case .blur: o.background = .blur(blur)
        case .color: o.background = .color(UIColor(color).cgColor)
        }
        o.edgeSoftness = softness
        o.cropToSubject = cropToSubject
        o.removeEnclosedBackground = removeEnclosed
        o.subjectMargin = margin
        o.excludedPoints = excluded.compactMap { preview.analysis?.anchor(of: $0) }
        return o
    }

    private var subjectCount: Int { preview.analysis?.allInstances.count ?? 0 }
    private var others: [UUID] { otherIDs(session, except: itemID) }

    var body: some View {
        ToolScaffold(title: "الخلفية", canApply: (preview.analysis != nil || preview.plainBackground) && !preview.working && preview.message == nil,
                     onApply: apply, onClose: onClose) {
            PreviewCanvas(image: preview.image, checker: fill == .transparent, onTap: tap) { _ in EmptyView() }
                .overlay(alignment: .bottom) {
                    StatusPill(working: preview.working, message: preview.message,
                               hint: subjectCount > 1 ? "المس أي شخص أو شي عشان تشيله أو ترجعه" : nil)
                }
        } controls: {
            ToolSection("بدال الخلفية") {
                Picker("الخلفية", selection: $fill) {
                    Text("شفافة").tag(Fill.transparent)
                    Text("مموّهة").tag(Fill.blur)
                    Text("لون").tag(Fill.color)
                }
                .pickerStyle(.segmented)
                if fill == .blur {
                    LabeledSlider(title: "قوة التمويه", value: $blur, range: 0.1...1)
                }
                if fill == .color {
                    HStack(spacing: 8) {
                        ForEach(Self.swatches, id: \.self) { swatch in
                            Circle()
                                .fill(swatch)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                                .overlay(Circle().stroke(Theme.gold, lineWidth: color == swatch ? 3 : 0).padding(-4))
                                .onTapGesture { color = swatch }
                        }
                        Spacer(minLength: 4)
                        ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
            }

            ToolSection {
                LabeledSlider(title: "نعومة الحواف", value: $softness, range: 0...0.6)
                if preview.plainBackground && excluded.isEmpty {
                    Toggle("شيل لون الخلفية حتى داخل الشكل", isOn: $removeEnclosed)
                }
                Toggle("قص على الموضوع", isOn: $cropToSubject)
                if cropToSubject {
                    LabeledSlider(title: "المسافة حوله", value: $margin, range: 0...0.4)
                }
            } header: {
                Text("الحواف والقص")
            } footer: {
                Text(preview.plainBackground && excluded.isEmpty
                     ? "الخلفية لون واحد، فتنشال بدقة مع حواف ناعمة بدون هالة. فعّل «حتى داخل الشكل» للشعارات والنصوص اللي فيها فراغات مثل حرف O."
                     : subjectCount > 1
                     ? "لقيت \(subjectCount) عناصر في الصورة. المس أي واحد في المعاينة عشان تشيله أو ترجعه."
                     : "يفصل الشخص أو الشي الأساسي. القص على الموضوع يشيل المساحة الفاضية حوله.")
            }

            if !others.isEmpty {
                ToolSection {
                    Toggle("طبّق على كل الصور (\(others.count + 1))", isOn: $applyToAll)
                } footer: {
                    Text("في باقي الصور ينفصل كل شخص أو شي يلقاه.")
                }
            }
        }
        .task {
            await preview.analyze()
            preview.render(options)
        }
        .onValueChange(of: fill) { _ in preview.render(options) }
        .onValueChange(of: blur) { _ in preview.render(options) }
        .onValueChange(of: color) { _ in preview.render(options) }
        .onValueChange(of: softness) { _ in preview.render(options) }
        .onValueChange(of: cropToSubject) { _ in preview.render(options) }
        .onValueChange(of: removeEnclosed) { _ in preview.render(options) }
        .onValueChange(of: margin) { _ in preview.render(options) }
        .onValueChange(of: excluded) { _ in preview.render(options) }
    }

    private func tap(_ p: CGPoint) {
        guard !cropToSubject, let a = preview.analysis, let i = a.instance(at: p) else { return }
        if excluded.contains(i) {
            excluded.remove(i)
        } else if excluded.count + 1 < a.allInstances.count {
            excluded.insert(i)
        }
    }

    private func apply() {
        let o = options
        Task { await session.applyTools(o, primary: itemID, others: applyToAll ? others : []) }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// true: show the position inside the range; false: show the value itself as a percentage.
    var relative = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(((relative ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : value) * 100).rounded()))٪")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Size

struct ResizeToolView: View {
    @ObservedObject var session: CleanSession
    let itemID: UUID
    let onClose: () -> Void
    @StateObject private var preview: ToolPreview

    enum Preset: String, CaseIterable, Identifiable {
        case square, portrait, story, wide, youtube, xHeader, profile, custom, p75, p50, p25
        var id: String { rawValue }
        var title: String {
            switch self {
            case .square: return "مربع"
            case .portrait: return "بوست عمودي"
            case .story: return "ستوري"
            case .wide: return "عريض"
            case .youtube: return "يوتيوب"
            case .xHeader: return "غلاف X"
            case .profile: return "بروفايل"
            case .custom: return "مخصص"
            case .p75: return "٧٥٪"
            case .p50: return "٥٠٪"
            case .p25: return "٢٥٪"
            }
        }
        var subtitle: String {
            switch self {
            case .square: return "1080×1080"
            case .portrait: return "1080×1350"
            case .story: return "1080×1920"
            case .wide: return "1600×900"
            case .youtube: return "1280×720"
            case .xHeader: return "1500×500"
            case .profile: return "400×400"
            case .custom: return "اكتب المقاس"
            case .p75, .p50, .p25: return "تصغير"
            }
        }
        var symbol: String {
            switch self {
            case .square, .profile: return "square"
            case .portrait: return "rectangle.portrait"
            case .story: return "iphone"
            case .wide, .youtube: return "rectangle"
            case .xHeader: return "rectangle.compress.vertical"
            case .custom: return "slider.horizontal.3"
            case .p75, .p50, .p25: return "arrow.down.right.and.arrow.up.left"
            }
        }
        var pixels: (Int, Int)? {
            switch self {
            case .square: return (1080, 1080)
            case .portrait: return (1080, 1350)
            case .story: return (1080, 1920)
            case .wide: return (1600, 900)
            case .youtube: return (1280, 720)
            case .xHeader: return (1500, 500)
            case .profile: return (400, 400)
            default: return nil
            }
        }
        var scale: Double? {
            switch self {
            case .p75: return 0.75
            case .p50: return 0.5
            case .p25: return 0.25
            default: return nil
            }
        }
    }

    @State private var preset: Preset = .square
    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var smartCrop = true
    @State private var focus: CGPoint? = nil
    @State private var autoFocus: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var zoom: Double = 1
    @State private var dragStart: CGPoint? = nil
    @State private var zoomStart: Double? = nil
    @State private var applyToAll = false
    private let fullSize: CGSize

    init(session: CleanSession, itemID: UUID, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.session = session
        self.itemID = itemID
        let data = session.items.first { $0.id == itemID }?.editableData
        _preview = StateObject(wrappedValue: ToolPreview(data: data))
        fullSize = data.flatMap(Self.pixelSize) ?? .zero
    }

    private static func pixelSize(_ data: Data) -> CGSize? {
        guard let image = try? ImageTools.decode(data, maxSide: 64) else { return nil }
        // decode() applies orientation; get the real size from the header with the same orientation
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let rotated = (image.width > image.height) != (w > h) && w != h
        return rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private var target: SizeTarget? {
        if let s = preset.scale { return .scale(s) }
        if let p = preset.pixels { return .pixels(p.0, p.1) }
        guard let w = Int(asciiDigits(customWidth)), let h = Int(asciiDigits(customHeight)),
              (1...ImageTools.maxSide).contains(w), (1...ImageTools.maxSide).contains(h) else { return nil }
        return .pixels(w, h)
    }

    private var cropTarget: (Int, Int)? {
        if case .pixels(let w, let h)? = target, smartCrop { return (w, h) }
        return nil
    }

    private var resultText: String {
        let text = rawResultText
        return text.isEmpty ? "" : "\u{2066}\(text)\u{2069}"      // keep "W×H" left-to-right in Arabic text
    }

    private var rawResultText: String {
        guard let target, fullSize.width > 0 else { return "" }
        switch target {
        case .scale(let s):
            return "\(Int((fullSize.width * s).rounded()))×\(Int((fullSize.height * s).rounded()))"
        case .pixels(let w, let h):
            if smartCrop { return "\(w)×\(h)" }
            let s = min(Double(w) / fullSize.width, Double(h) / fullSize.height)
            return "\(Int((fullSize.width * s).rounded()))×\(Int((fullSize.height * s).rounded()))"
        }
    }

    private var others: [UUID] { otherIDs(session, except: itemID) }

    var body: some View {
        ToolScaffold(title: "المقاس", canApply: target != nil, onApply: apply, onClose: onClose) {
            Group {
                if let t = cropTarget {
                    ZoomCropCanvas(image: preview.source, crop: currentCrop(t),
                                   targetAspect: Double(t.0) / Double(t.1),
                                   onPan: pan, onPanEnd: { dragStart = nil },
                                   onPinch: pinch, onPinchEnd: { zoomStart = nil })
                } else {
                    PreviewCanvas(image: preview.source) { _ in EmptyView() }
                }
            }
            .overlay(alignment: .bottom) {
                StatusPill(working: false, message: nil,
                           hint: resultText.isEmpty ? nil : "النتيجة: \(resultText)" + (cropTarget != nil ? " · قرّص واسحب" : ""))
            }
        } controls: {
            ToolSection("المقاس") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Preset.allCases) { p in
                            Button { preset = p } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: p.symbol).font(.title3)
                                    Text(p.title).font(.toa(.caption, .bold))
                                    Text(p.subtitle).font(.toa(.caption2)).foregroundStyle(Theme.inkSecondary)
                                }
                                .frame(width: 86, height: 76)
                                .background(RoundedRectangle(cornerRadius: 14)
                                    .fill(preset == p ? Theme.green.opacity(0.10) : Theme.surfaceSunken))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .stroke(preset == p ? Theme.green : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if preset == .custom {
                    HStack {
                        TextField("العرض", text: $customWidth).keyboardType(.numberPad)
                        Text("×").foregroundStyle(.secondary)
                        TextField("الارتفاع", text: $customHeight).keyboardType(.numberPad)
                    }
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    if target == nil {
                        Label("اكتب العرض والارتفاع (من 1 إلى \(ImageTools.maxSide))", systemImage: "exclamationmark.circle")
                            .font(.toa(.footnote))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }

            if preset.scale == nil {
                ToolSection {
                    Picker("الطريقة", selection: $smartCrop) {
                        Text("قص ذكي").tag(true)
                        Text("بدون قص").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if smartCrop {
                        HStack(spacing: 10) {
                            Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.inkSecondary)
                            Slider(value: $zoom, in: 1...6)
                            Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.inkSecondary)
                            Text("\(Int((zoom * 100).rounded()))%")
                                .font(.toa(.footnote, .semibold)).monospacedDigit()
                                .frame(minWidth: 48)
                        }
                        HStack(spacing: 8) {
                            Button("ملء الإطار") { zoom = 1 }
                            Button("تكبير ٢×") { zoom = 2 }
                            Button("تلقائي") { zoom = 1; focus = nil }
                        }
                        .buttonStyle(.bordered)
                        .font(.toa(.footnote, .semibold))
                    }
                } footer: {
                    Text(smartCrop
                         ? "الإطار ثابت والصورة تتحرك تحته: قرّص بإصبعين للتكبير والتصغير، واسحب لتحريكها. يبدأ حول أهم شي في الصورة."
                         : "يحافظ على الصورة كاملة ويصغّرها لين تدخل في المقاس.")
                }
            }

            if !others.isEmpty {
                ToolSection {
                    Toggle("طبّق على كل الصور (\(others.count + 1))", isOn: $applyToAll)
                } footer: {
                    Text("كل صورة يصير القص فيها حول أهم شي تلقائياً.")
                }
            }
        }
        .onValueChange(of: preset) { _ in
            zoom = 1
            if preset == .custom, asciiDigits(customWidth).isEmpty, fullSize.width > 0 {
                customWidth = String(Int(fullSize.width))          // start from the image's own size
                customHeight = String(Int(fullSize.height))
            }
        }
        .task {
            guard let src = preview.source else { return }
            autoFocus = await Task.detached(priority: .userInitiated) { ImageTools.autoFocus(src) }.value
        }
    }

    private func apply() {
        guard let target else { return }
        var o = EditOptions()
        o.size = target
        o.resizeMode = smartCrop ? .smartCrop : .fit
        o.focus = focus ?? autoFocus
        if let t = cropTarget { o.crop = currentCrop(t) }
        let all = applyToAll ? others : []
        Task { await session.applyTools(o, primary: itemID, others: all) }
    }
}

extension ResizeToolView {
    func currentCrop(_ t: (Int, Int)) -> CGRect {
        ImageTools.cropRect(imageWidth: fullSize.width, imageHeight: fullSize.height,
                            targetWidth: t.0, targetHeight: t.1, center: focus ?? autoFocus, zoom: zoom)
    }

    /// Dragging the photo: it follows the finger, so the crop centre moves the other way.
    func pan(_ translation: CGSize, _ displayedImageSize: CGSize) {
        guard displayedImageSize.width > 0, displayedImageSize.height > 0, let t = cropTarget else { return }
        let c = currentCrop(t)
        let start = dragStart ?? CGPoint(x: c.midX, y: c.midY)
        if dragStart == nil { dragStart = start }
        let hx = c.width / 2, hy = c.height / 2
        focus = CGPoint(x: min(max(start.x - translation.width / displayedImageSize.width, hx), 1 - hx),
                        y: min(max(start.y - translation.height / displayedImageSize.height, hy), 1 - hy))
    }

    func pinch(_ scale: CGFloat) {
        let start = zoomStart ?? zoom
        if zoomStart == nil { zoomStart = start }
        zoom = min(max(start * Double(scale), 1), 6)
    }
}

/// Fixed crop frame; the photo is scaled and moved underneath it.
struct ZoomCropCanvas: View {
    @Environment(\.layoutDirection) private var direction
    let image: CGImage?
    let crop: CGRect                 // normalized part of the image inside the frame
    let targetAspect: Double         // width / height of the frame
    let onPan: (CGSize, CGSize) -> Void
    let onPanEnd: () -> Void
    let onPinch: (CGFloat) -> Void
    let onPinchEnd: () -> Void

    var body: some View {
        GeometryReader { geo in
            let frame = frameRect(in: geo.size)
            let shown = CGSize(width: frame.width / max(crop.width, 0.0001),
                               height: frame.height / max(crop.height, 0.0001))
            let origin = CGPoint(x: frame.minX - crop.minX * shown.width, y: frame.minY - crop.minY * shown.height)
            let x = PhysicalX(direction: direction, width: geo.size.width)
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: shown.width, height: shown.height)
                        .position(x: x(origin.x + shown.width / 2), y: origin.y + shown.height / 2)
                }
                // Dim everything outside the frame
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(Theme.gold, lineWidth: 2)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: x(frame.midX), y: frame.midY)
                Path { p in
                    for k in 1...2 {
                        let x = frame.minX + frame.width * CGFloat(k) / 3
                        let y = frame.minY + frame.height * CGFloat(k) / 3
                        p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                        p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)   // screen space: never mirrored
                        .onChanged { onPan($0.translation, shown) }
                        .onEnded { _ in onPanEnd() },
                    MagnificationGesture()
                        .onChanged { onPinch($0) }
                        .onEnded { _ in onPinchEnd() }
                )
            )
        }
        // Pixels are placed through PhysicalX; drags use screen space (see PreviewCanvas).
    }

    private func frameRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let inset: CGFloat = 16
        let w0 = size.width - inset * 2, h0 = size.height - inset * 2
        var w = w0, h = w0 / targetAspect
        if h > h0 { h = h0; w = h0 * targetAspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

struct CropOverlay: View {
    let frame: CGRect
    let crop: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(frame)
                p.addRect(crop)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

            Rectangle()
                .stroke(Theme.gold, lineWidth: 2)
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)

            // Rule-of-thirds guides
            Path { p in
                for k in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(k) / 3
                    let y = crop.minY + crop.height * CGFloat(k) / 3
                    p.move(to: CGPoint(x: x, y: crop.minY)); p.addLine(to: CGPoint(x: x, y: crop.maxY))
                    p.move(to: CGPoint(x: crop.minX, y: y)); p.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Format

struct FormatToolView: View {
    @ObservedObject var session: CleanSession
    let itemID: UUID
    let onClose: () -> Void
    @StateObject private var preview: ToolPreview

    @State private var format: OutputFormat
    @State private var quality = 0.9
    @State private var estimate: String? = nil
    @State private var estimating = false
    @State private var applyToAll = false
    private let currentFormat: OutputFormat?
    private let currentBytes: Int
    private let transparent: Bool
    private let canTrace: Bool
    private var choices: [OutputFormat] { OutputFormat.allCases.filter { $0 != .svg || canTrace } }

    init(session: CleanSession, itemID: UUID, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.session = session
        self.itemID = itemID
        let item = session.items.first { $0.id == itemID }
        let preview = ToolPreview(data: item?.editableData)
        _preview = StateObject(wrappedValue: preview)
        currentFormat = OutputFormat(fileExtension: ((item?.outputName ?? "") as NSString).pathExtension)
        currentBytes = item?.data?.count ?? 0
        transparent = preview.source.map(ImageTools.hasAlpha) ?? false
        _format = State(initialValue: currentFormat == .jpeg ? .heic : .jpeg)
        canTrace = preview.source.map(Vectorizer.canTrace) ?? false
    }

    private var others: [UUID] { otherIDs(session, except: itemID) }

    private var about: String {
        switch format {
        case .jpeg: return "الأنسب للمشاركة والمواقع، حجمه صغير. ما يدعم الشفافية."
        case .png: return "بدون أي فقد في الجودة ويدعم الشفافية، بس حجمه أكبر."
        case .heic: return "جودة عالية بحجم صغير ويدعم الشفافية. بعض المواقع والأجهزة القديمة ما تدعمه."
        case .svg: return "يحوّل الشعار لرسمة متجهة (Vector) تتكبّر بأي مقاس بدون ما تتكسر. مناسب للشعارات والرسومات اللي ألوانها قليلة، مو للصور الفوتوغرافية."
        }
    }

    var body: some View {
        ToolScaffold(title: "الصيغة", canApply: true, onApply: apply, onClose: onClose) {
            PreviewCanvas(image: preview.source, checker: transparent) { _ in EmptyView() }
                .overlay(alignment: .bottom) {
                    StatusPill(working: estimating, message: nil, hint: estimate)
                }
        } controls: {
            ToolSection {
                Picker("الصيغة", selection: $format) {
                    ForEach(choices) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if format.isLossy {
                    LabeledSlider(title: "الجودة", value: $quality, range: 0.5...1, relative: false)
                }
            } header: {
                Text("الصيغة الجديدة" + (currentFormat.map { " (الحالية \($0.title))" } ?? ""))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(about)
                    if transparent && !format.supportsTransparency {
                        Label("الصورة فيها شفافية — بتصير الخلفية بيضاء", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !others.isEmpty {
                ToolSection {
                    Toggle("طبّق على كل الصور (\(others.count + 1))", isOn: $applyToAll)
                }
            }
        }
        .task(id: "\(format.rawValue)-\(quality)") { await estimateSize() }
    }

    private func estimateSize() async {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        guard let data = session.items.first(where: { $0.id == itemID })?.editableData else { return }
        estimating = true
        let f = format, q = quality
        let bytes = await Task.detached(priority: .userInitiated) { () -> Int? in
            guard let image = try? ImageTools.decode(data, maxSide: nil) else { return nil }
            var output = image
            if !f.supportsTransparency && ImageTools.hasAlpha(image) {
                output = (try? ImageTools.render(image, width: image.width, height: image.height,
                                                 background: CGColor(red: 1, green: 1, blue: 1, alpha: 1))) ?? image
            }
            if f == .svg { return (try? Vectorizer.trace(output))?.count }
            return (try? ImageTools.encode(output, as: f, quality: q))?.count
        }.value
        if Task.isCancelled { return }
        estimating = false
        if let bytes {
            estimate = "الحجم: \(sizeText(currentBytes)) ← \(sizeText(bytes))"
        } else {
            estimate = nil
        }
    }

    private func sizeText(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }

    private func apply() {
        var o = EditOptions()
        o.format = format
        o.quality = quality
        Task { await session.applyTools(o, primary: itemID, others: applyToAll ? others : []) }
    }
}

/// Arabic-Indic / Persian keyboards type ٠١٢٣٤٥٦٧٨٩ / ۰۱۲۳۴۵۶۷۸۹ — Int() only reads 0–9.
func asciiDigits(_ s: String) -> String {
    String(s.compactMap { ch -> Character? in
        if let v = ch.wholeNumberValue, ch.isNumber { return Character(String(v)) }
        return nil
    })
}

/// One group of settings: optional title, a white card, optional explanation under it.
struct ToolSection<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header()
                .font(.toa(.footnote, .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
            footer()
                .font(.toa(.footnote))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

extension ToolSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension ToolSection where Header == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension ToolSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}
