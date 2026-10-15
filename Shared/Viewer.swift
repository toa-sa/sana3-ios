//
//  Viewer.swift
//  Image Cleaner — TOA
//
//  Full-screen image viewer: swipe between images, pinch / double-tap to zoom,
//  before/after compare, glass controls, scan details sheet.
//

import SwiftUI
import UIKit

// MARK: - Glass

extension View {
    /// Apple's Liquid Glass where available (iOS 26+), a material blur on iOS 18–25.
    @ViewBuilder
    func toaGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
                .background(shape.fill((tint ?? .clear).opacity(0.35)))
                .overlay(shape.stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
    }
}

// MARK: - Decoded previews

@MainActor
final class PreviewCache: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]

    func image(for key: String, data: Data?) -> UIImage? {
        if let img = images[key] { return img }
        guard let data else { return nil }
        Task {
            let img = await Task.detached(priority: .userInitiated) {
                (try? ImageTools.decode(data, maxSide: 2200)).map { UIImage(cgImage: $0) }
            }.value
            if let img {
                if images.count > 12 { images.removeAll() }       // keep memory small
                images[key] = img
            }
        }
        return nil
    }
}

// MARK: - Zoomable page

struct ZoomableImage: View {
    @Environment(\.layoutDirection) private var direction
    let image: UIImage?
    var checker = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .background(checker ? AnyView(Checkerboard()) : AnyView(Color.clear))
                        .scaleEffect(scale)
                        // `offset` is a physical (screen) shift; RTL layout mirrors x (see PhysicalX).
                        .offset(x: direction == .rightToLeft ? -offset.width : offset.width, y: offset.height)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
            .gesture(MagnificationGesture()
                .onChanged { v in scale = min(6, max(1, lastScale * v)) }
                .onEnded { _ in
                    lastScale = scale
                    if scale <= 1.01 { reset() }
                })
            .simultaneousGesture(scale > 1 ? DragGesture(coordinateSpace: .global)
                .onChanged { v in
                    offset = CGSize(width: lastOffset.width + v.translation.width,
                                    height: lastOffset.height + v.translation.height)
                }
                .onEnded { _ in lastOffset = offset } : nil)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3)) {
                    if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
                }
            }
        }
    }

    private func reset() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }
}

// MARK: - Before / after

struct CompareSlider: View {
    @Environment(\.layoutDirection) private var direction
    let before: UIImage
    let after: UIImage
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            let rect = fitted(after.size, in: geo.size)
            let x = PhysicalX(direction: direction, width: geo.size.width)
            let left = geo.frame(in: .global).minX
            ZStack {
                Checkerboard()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: x(rect.midX), y: rect.midY)
                Image(uiImage: after).resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: x(rect.midX), y: rect.midY)
                Image(uiImage: before).resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: x(rect.midX), y: rect.midY)
                    .mask {
                        // The mask lives in the image's own frame (rect.size), not the canvas.
                        let m = PhysicalX(direction: direction, width: rect.width)
                        Rectangle()
                            .frame(width: rect.width * split, height: rect.height)
                            .position(x: m(rect.width * split / 2), y: rect.height / 2)
                    }
                // Divider + handle
                Rectangle().fill(.white)
                    .frame(width: 2, height: rect.height)
                    .shadow(radius: 2)
                    .position(x: x(rect.minX + rect.width * split), y: rect.midY)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.green)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white))
                    .shadow(radius: 3)
                    .position(x: x(rect.minX + rect.width * split), y: rect.midY)
                // "Before" sits over the left part (the original), "after" over the right.
                tag("قبل").position(x: x(rect.minX + 36), y: rect.minY + 22)
                tag("بعد").position(x: x(rect.maxX - 36), y: rect.minY + 22)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { v in
                guard rect.width > 0 else { return }
                split = min(1, max(0, (v.location.x - left - rect.minX) / rect.width))
            })
        }
        // Pixels are placed through PhysicalX (see PreviewCanvas); no layout-direction override.
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.toa(.caption, .bold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private func fitted(_ img: CGSize, in size: CGSize) -> CGRect {
        guard img.width > 0, img.height > 0 else { return .zero }
        let s = min(size.width / img.width, size.height / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: - Viewer panel (replaces the old scan panel)

struct ViewerPanel: View {
    @ObservedObject var session: CleanSession
    @Binding var selectedID: UUID?
    let current: CleanedItem
    var onTool: (EditorTool) -> Void

    @StateObject private var cache = PreviewCache()
    @State private var comparing = false
    @State private var holdingOriginal = false
    @State private var showDetails = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.surfaceSunken.ignoresSafeArea(edges: .bottom)

            if comparing, current.isEdited,
               let before = cache.image(for: "clean-\(current.id)-\(current.cleanData?.count ?? 0)", data: current.isSVG ? current.cleanSVGRaster : current.cleanData),
               let after = cache.image(for: key(current), data: current.editableData) {
                CompareSlider(before: before, after: after)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 96)
            } else {
                TabView(selection: Binding(get: { selectedID ?? current.id }, set: { selectedID = $0 })) {
                    ForEach(session.items) { item in
                        page(item).tag(Optional(item.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: session.items.count > 1 ? .automatic : .never))
                .padding(.bottom, 84)
            }

            controls
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .sheet(isPresented: $showDetails) {
            ScanDetails(item: current)
                .mediumSheet()
        }
    }

    private func key(_ item: CleanedItem) -> String {
        "\(item.id)-\(item.data?.count ?? 0)-\(item.outputName)"
    }

    @ViewBuilder
    private func page(_ item: CleanedItem) -> some View {
        let shown: UIImage? = (holdingOriginal && item.id == current.id && item.isEdited)
            ? cache.image(for: "clean-\(item.id)-\(item.cleanData?.count ?? 0)", data: item.isSVG ? item.cleanSVGRaster : item.cleanData)
            : (cache.image(for: key(item), data: item.editableData) ?? item.thumbnail)
        if item.data == nil {
            VStack(spacing: 10) {
                Image(systemName: "xmark.octagon").font(.system(size: 44)).foregroundStyle(Theme.error)
                Text(item.error ?? "").font(.toa(.footnote)).foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        } else {
            ZoomableImage(image: shown, checker: item.outputName.lowercased().hasSuffix(".png"))
                .padding(10)
                .overlay(alignment: .top) {
                    if holdingOriginal && item.id == current.id && item.isEdited {
                        Text("الأصلية (قبل التعديل)")
                            .font(.toa(.caption, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .padding(.top, 16)
                    }
                }
                .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30, perform: {}, onPressingChanged: { pressing in
                    holdingOriginal = pressing && item.isEdited
                })
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if let url = current.fileURL {
                ShareButton(urls: [url]) {
                    Label("مشاركة", systemImage: "square.and.arrow.up")
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 6)
                        .font(.toa(.callout, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .toaGlass(in: Capsule(), tint: Theme.green)
                .disabled(session.isWorking)

                Button {
                    Task { await session.saveToPhotos([current.id]) }
                } label: {
                    Label("حفظ", systemImage: "square.and.arrow.down")
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 6)
                        .font(.toa(.callout, .semibold))
                        .foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .toaGlass(in: Capsule())
                .disabled(session.isWorking)
            }
            if current.isEdited {
                Button {
                    withAnimation(.snappy) { comparing.toggle() }
                } label: {
                    Image(systemName: comparing ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(comparing ? .white : Theme.green)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .toaGlass(in: Circle(), tint: comparing ? Theme.gold : nil)
                .accessibilityLabel("قبل وبعد")
            }
            Button { showDetails = true } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.green)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .toaGlass(in: Circle())
            .accessibilityLabel("تفاصيل الفحص")
        }
    }
}

/// Everything the scan found and removed, plus the edits (sheet).
struct ScanDetails: View {
    let item: CleanedItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "تفاصيل الفحص", onDone: { dismiss() }) {
            ToolSection("نتيجة الفحص") {
                if let error = item.error {
                    row(error, "xmark.octagon.fill", Theme.error)
                }
                ForEach(item.warnings, id: \.self) { w in row(w, "exclamationmark.triangle.fill", Theme.warning) }
                if item.error == nil && item.warnings.isEmpty {
                    row("ما فيها أي شي مشبوه", "checkmark.seal.fill", Theme.success)
                }
            }
            if !item.removedInfo.isEmpty {
                ToolSection("البيانات اللي انشالت") {
                    ForEach(item.removedInfo, id: \.self) { r in row(r, "minus.circle.fill", Theme.ink) }
                }
            }
            if item.editNote != nil || !item.editWarnings.isEmpty {
                ToolSection("التعديلات") {
                    if let note = item.editNote { row(note, "slider.horizontal.3", Theme.goldInk) }
                    ForEach(item.editWarnings, id: \.self) { w in row(w, "exclamationmark.triangle.fill", Theme.warning) }
                }
            }
            if !item.summaryLine.isEmpty {
                ToolSection("الملف") {
                    Text(item.outputName.isEmpty ? item.displayName : item.outputName)
                    Text(item.summaryLine).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .font(.toa(.footnote))
    }

    private func row(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sheet with its own title bar and "تم", content in cards. Used instead of a navigation bar
/// and List: those system views were drawn mirrored (Arabic backwards) on iOS 15–16 in this app.
struct SheetScaffold<Content: View>: View {
    let title: String
    let onDone: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.toa(.headline, .bold)).foregroundStyle(Theme.ink)
                HStack {
                    Spacer()
                    Button(action: onDone) {
                        Text("تم")
                            .font(.toa(.body, .bold))
                            .foregroundStyle(Theme.green)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Theme.surfaceRaised)
            .overlay(alignment: .bottom) { Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content() }
                    .padding(16)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
            }
            .background(Theme.surface)
        }
        .background(Theme.surface.ignoresSafeArea())
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    let onDone: () -> Void
    @State private var page = 0

    private let cards: [(String, String, String)] = [
        ("checkmark.shield.fill", "نظّف صورك", "يشيل الموقع وبيانات الجهاز ووسوم الذكاء الاصطناعي، ويفحص الصورة من أي ملفات مدسوسة — بنفس الجودة بالضبط."),
        ("wand.and.stars", "أدوات قوية", "شيل الخلفية، غيّر المقاس بقص ذكي، وحوّل الصيغة. وقارن قبل وبعد بسحبة."),
        ("square.and.arrow.up.fill", "شارك بأمان", "شارك مباشرة من التطبيق، أو من أي تطبيق عن طريق المشاركة، أو قل لـ Siri: «نظّف هذي الصورة»."),
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)
            AppMark(size: 104)
            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { i in
                    VStack(spacing: 14) {
                        Image(systemName: cards[i].0)
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Theme.gold)
                        Text(cards[i].1).font(.toa(.title2, .bold)).foregroundStyle(Theme.green)
                        Text(cards[i].2)
                            .font(.toa(.body))
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(height: 300)
            Spacer(minLength: 20)
            Button {
                if page < cards.count - 1 { withAnimation { page += 1 } } else { onDone() }
            } label: {
                Text(page < cards.count - 1 ? "التالي" : "ابدأ").frame(maxWidth: .infinity)
            }
            .buttonStyle(TOAButtonStyle(kind: .primary))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .interactiveDismissDisabled()
    }
}


