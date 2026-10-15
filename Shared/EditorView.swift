//
//  EditorView.swift
//  Image Cleaner — TOA
//
//  One image, full screen: scan result on top, the image in the middle,
//  a fixed side toolbar (scan, background, size, format, undo), Save / Share at the bottom.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable, Identifiable {
    case scan, background, resize, format
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "الفحص"
        case .background: return "الخلفية"
        case .resize: return "المقاس"
        case .format: return "الصيغة"
        }
    }

    var symbol: String {
        switch self {
        case .scan: return "checkmark.shield"
        case .background: return "person.and.background.dotted"
        case .resize: return "crop"
        case .format: return "arrow.triangle.2.circlepath"
        }
    }
}

/// The main screen (app and Share Extension): scan strip, image strip, side toolbar and the current tool.
struct WorkspaceView: View {
    @ObservedObject var session: CleanSession
    /// App: open the photo / file pickers. Nil in the Share Extension.
    var onAddPhotos: (() -> Void)? = nil
    var onAddFiles: (() -> Void)? = nil
    var onCleanAndShare: (() -> Void)? = nil
    /// App: images dropped onto the window or pasted (item providers).
    var onReceive: (([NSItemProvider]) -> Void)? = nil
    var onAbout: (() -> Void)? = nil
    /// Share Extension: the "تم" button.
    var onDone: (() -> Void)? = nil

    @State private var selectedID: UUID? = nil
    @State private var tool: EditorTool = .scan

    private var item: CleanedItem? {
        session.items.first { $0.id == selectedID } ?? session.items.first
    }
    /// Changes whenever the image data changes, so tool screens start from the latest version.
    private var version: String { "\(item?.id.uuidString ?? "")-\(item?.data?.count ?? 0)-\(item?.editNote ?? "")" }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let item {
                ScanStrip(item: item)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                if session.items.count > 1 || onAddPhotos != nil {
                    ThumbStrip(session: session, selectedID: item.id, onSelect: select, onAdd: onAddPhotos,
                               onTool: { id, t in select(id); tool = t })
                }
            }
            HStack(spacing: 0) {
                SideToolbar(selected: $tool,
                            canRevert: item?.history.isEmpty == false,
                            canEdit: item?.data != nil && !session.isWorking,
                            onRevert: {
                                if let id = item?.id { session.undoLastEdit(id) }
                                tool = .scan
                            },
                            onRevertAll: {
                                if let id = item?.id { session.revertTools(id) }
                                tool = .scan
                            })
                .padding(.leading, 8)
                .padding(.vertical, 8)
                Group {
                    if let item {
                        content(item).id(tool == .scan ? "scan" : "\(tool.rawValue)-\(version)")
                    } else {
                        EmptyCanvas(session: session, onAddPhotos: onAddPhotos, onAddFiles: onAddFiles,
                                    onCleanAndShare: onCleanAndShare, onPaste: onReceive)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.surfaceSunken)
        }
        .haptic(.success, trigger: session.feedbackTick)
        .haptic(.selection, trigger: tool)
        .onDrop(of: [.image], isTargeted: nil) { providers in
            guard let onReceive, !session.isWorking else { return false }
            onReceive(providers)
            return true
        }
        .background(Theme.surface)
        .font(.toa())
        .tint(Theme.green)
        // Right-to-left comes from the app being Arabic-only (ar.lproj). Never force it with
        // .environment(\.layoutDirection): on iOS 15–16 that mirrors every list, segmented control
        // and share sheet a second time (text drawn backwards).
        .actionMenuHost()
        .onValueChange(of: session.focusID) { id in
            if let id { select(id) }           // a new batch: show its first image
        }
    }

    private func select(_ id: UUID) {
        selectedID = id
        tool = .scan
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("سنع")
                .font(.toa(.title3, .bold))
                .foregroundStyle(Theme.green)
            if session.isWorking {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if let onAddPhotos, let onAddFiles {
                Button {
                    var items = [ActionItem(title: "من الصور", symbol: "photo.on.rectangle", action: onAddPhotos),
                                 ActionItem(title: "من الملفات", symbol: "folder", action: onAddFiles)]
                    if let onReceive, UIPasteboard.general.hasImages {
                        items.append(ActionItem(title: "لصق صورة", symbol: "doc.on.clipboard") {
                            onReceive(UIPasteboard.general.itemProviders)
                        })
                    }
                    if let onCleanAndShare {
                        items.append(ActionItem(title: "نظّف وشارك", symbol: "bolt.fill", action: onCleanAndShare))
                    }
                    ActionMenuCenter.shared.show("إضافة صور", items)
                } label: {
                    headerIcon("plus")
                }
                .accessibilityLabel("إضافة صور")
                .disabled(session.isWorking)
            }
            if session.items.count > 1 {
                Button {
                    let urls = session.shareURLs
                    ActionMenuCenter.shared.show("كل الصور", [
                        ActionItem(title: "مشاركة الكل (\(urls.count))", symbol: "square.and.arrow.up") { ShareCenter.present(urls) },
                        ActionItem(title: "حفظ الكل في الصور", symbol: "square.and.arrow.down") {
                            Task { await session.saveAllToPhotos() }
                        },
                        ActionItem(title: "مسح الكل", symbol: "trash", destructive: true) { session.clear() },
                    ])
                } label: {
                    headerIcon("ellipsis")
                }
                .accessibilityLabel("كل الصور")
                .disabled(session.isWorking)
            } else if !session.items.isEmpty && onDone == nil {
                Button { session.clear() } label: { headerIcon("trash") }
                    .accessibilityLabel("مسح")
                    .disabled(session.isWorking)
            }
            if let onAbout {
                Button(action: onAbout) { headerIcon("info.circle") }
                    .accessibilityLabel("عن التطبيق")
            }
            if let onDone {
                Button("تم", action: onDone)
                    .buttonStyle(TOAButtonStyle(kind: .primary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surfaceRaised)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.green)
            .frame(width: 40, height: 40)
            .toaGlass(in: Circle())
    }

    @ViewBuilder
    private func content(_ item: CleanedItem) -> some View {
        switch tool {
        case .scan:
            ViewerPanel(session: session, selectedID: $selectedID, current: item) { tool = $0 }
        case .background:
            BackgroundToolView(session: session, itemID: item.id) { tool = .scan }
        case .resize:
            ResizeToolView(session: session, itemID: item.id) { tool = .scan }
        case .format:
            FormatToolView(session: session, itemID: item.id) { tool = .scan }
        }
    }
}

/// All picked images; tap one to work on it.
struct ThumbStrip: View {
    @ObservedObject var session: CleanSession
    let selectedID: UUID
    let onSelect: (UUID) -> Void
    var onAdd: (() -> Void)? = nil
    var onTool: ((UUID, EditorTool) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.items) { item in
                    Button { onSelect(item.id) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let t = item.thumbnail {
                                    Image(uiImage: t).resizable().scaledToFill()
                                } else {
                                    ZStack {
                                        Theme.errorBg
                                        Image(systemName: "xmark.octagon").foregroundStyle(Theme.error)
                                    }
                                }
                            }
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(item.id == selectedID ? Theme.gold : Theme.border, lineWidth: item.id == selectedID ? 3 : 1))
                            Circle()
                                .fill(dot(item))
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .offset(x: 3, y: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                        ActionMenuCenter.shared.show(item.displayName, menu(item))
                    })
                }
                if let onAdd {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.green)
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceSunken))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("إضافة صور")
                    .disabled(session.isWorking)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Theme.surface)
    }

    private func menu(_ item: CleanedItem) -> [ActionItem] {
        var items: [ActionItem] = []
        if let url = item.fileURL {
            items.append(ActionItem(title: "مشاركة", symbol: "square.and.arrow.up") { ShareCenter.present([url]) })
            items.append(ActionItem(title: "حفظ في الصور", symbol: "square.and.arrow.down") {
                Task { await session.saveToPhotos([item.id]) }
            })
            for t in [EditorTool.background, .resize, .format] {
                items.append(ActionItem(title: t.title, symbol: t.symbol) { onTool?(item.id, t) })
            }
        }
        if item.isEdited {
            items.append(ActionItem(title: "رجوع للنظيفة", symbol: "arrow.uturn.backward") { session.revertTools(item.id) })
        }
        items.append(ActionItem(title: "حذف من القائمة", symbol: "trash", destructive: true) { session.remove(item.id) })
        return items
    }

    private func dot(_ item: CleanedItem) -> Color {
        if item.error != nil { return Theme.error }
        if !item.warnings.isEmpty { return Theme.warning }
        return Theme.success
    }
}

/// Before any image is picked: logo, what the app does, and the two pick buttons.
struct EmptyCanvas: View {
    @ObservedObject var session: CleanSession
    let onAddPhotos: (() -> Void)?
    let onAddFiles: (() -> Void)?
    var onCleanAndShare: (() -> Void)? = nil
    var onPaste: (([NSItemProvider]) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AppMark(size: 120)
                    .padding(.top, 28)
                Text("نظّف صورك قبل ما تشاركها")
                    .font(.toa(.title3, .bold))
                    .foregroundStyle(Theme.green)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 8) {
                    Label("يشيل الموقع وبيانات الجهاز والتاريخ", systemImage: "location.slash")
                    Label("يشيل وسوم الذكاء الاصطناعي و Content Credentials", systemImage: "tag.slash")
                    Label("يفحص الصورة من أي ملفات أو أكواد مدسوسة", systemImage: "checkmark.shield")
                    Label("بنفس الجودة والريزوليوشن بالضبط", systemImage: "photo")
                }
                .font(.toa(.footnote))
                .foregroundStyle(Theme.inkSecondary)

                if session.isWorking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("جاري الفحص والتنظيف…").foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(.top, 8)
                } else if let onAddPhotos, let onAddFiles {
                    VStack(spacing: 10) {
                        Button(action: onAddPhotos) {
                            Label("من الصور", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TOAButtonStyle(kind: .primary))
                        Button(action: onAddFiles) {
                            Label("من الملفات", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TOAButtonStyle(kind: .secondary))
                        if let onCleanAndShare {
                            Button(action: onCleanAndShare) {
                                Label("نظّف وشارك بضغطة", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TOAButtonStyle(kind: .secondary))
                            .tint(Theme.goldInk)
                        }
                        if let onPaste {
                            PasteImagesButton(onPaste: onPaste)
                                .tint(Theme.green)
                        }
                    }
                    .padding(.top, 8)
                }
                if let status = session.statusMessage {
                    Text(status)
                        .font(.toa(.footnote))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 24)
                Text("الصور الأصلية ما تتغير")
                    .font(.toa(.caption))
                    .foregroundStyle(Theme.inkSecondary.opacity(0.7))
                Text("\u{2066}© \(Credits.owner) · @\(Credits.xHandle)\u{2069}")
                    .font(.toa(.caption2))
                    .foregroundStyle(Theme.inkSecondary.opacity(0.7))
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Side toolbar

struct SideToolbar: View {
    @Binding var selected: EditorTool
    let canRevert: Bool
    let canEdit: Bool
    let onRevert: () -> Void
    var onRevertAll: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            ForEach(EditorTool.allCases) { t in
                button(t.title, t.symbol, active: selected == t, enabled: t == .scan || canEdit) { selected = t }
            }
            Spacer(minLength: 8)
            button("تراجع", "arrow.uturn.backward", active: false, enabled: canRevert && canEdit, tint: Theme.goldInk, action: onRevert)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    guard canRevert, canEdit, let onRevertAll else { return }
                    ActionMenuCenter.shared.show(nil, [
                        ActionItem(title: "رجوع للنسخة النظيفة (يلغي كل التعديلات)", symbol: "arrow.counterclockwise",
                                   destructive: true, action: onRevertAll),
                    ])
                })
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: 78)
        .frame(maxHeight: .infinity)
        .toaGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), tint: Theme.green)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.green.opacity(0.85)))
    }

    private func button(_ title: String, _ symbol: String, active: Bool, enabled: Bool,
                        tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 24)
                Text(title)
                    .font(.toa(.caption2, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(active ? Theme.green : (tint == nil ? Color.white : Theme.gold))
            .background(RoundedRectangle(cornerRadius: 12).fill(active ? Theme.gold : Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(title)
    }
}

// MARK: - Scan

/// One-line result of the security scan, always visible above the image.
struct ScanStrip: View {
    let item: CleanedItem

    var body: some View {
        HStack(spacing: 8) {
            if let error = item.error {
                StatusBadge(kind: .error, text: "مرفوضة")
                Text(error).font(.toa(.caption)).foregroundStyle(Theme.error).lineLimit(2)
            } else if !item.warnings.isEmpty {
                StatusBadge(kind: .warning, text: "تنبيهات: \(item.warnings.count)")
                Text(summary).font(.toa(.caption)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            } else {
                StatusBadge(kind: .success, text: "نظيفة")
                Text(summary).font(.toa(.caption)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !item.summaryLine.isEmpty {
                Text(item.summaryLine)
                    .font(.toa(.caption, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.top, 8)
    }

    private var summary: String {
        item.removedInfo.isEmpty ? "ما كان فيها بيانات مخفية"
            : "انشال: " + item.removedInfo.prefix(3).joined(separator: "، ") + (item.removedInfo.count > 3 ? "…" : "")
    }
}

/// The app icon, used as the logo inside the app (app and Share Extension).
struct AppMark: View {
    var size: CGFloat = 120

    var body: some View {
        Image("AppMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }
}


