//
//  Compat.swift
//  Image Cleaner — TOA
//
//  The app runs from iOS 15 (TrollStore / jailbroken devices) up to the newest iOS.
//  Each helper uses the newest system control where it exists and an equivalent
//  that iOS 15 has otherwise, so the rest of the code reads the same on every version.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension View {
    /// `onChange` with the new value (the iOS 17 two-argument form, available everywhere).
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            onChange(of: value, perform: action)
        }
    }

    /// Haptic tick when `trigger` changes.
    @ViewBuilder
    func haptic<T: Equatable>(_ kind: HapticKind, trigger: T) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(kind == .success ? .success : .selection, trigger: trigger)
        } else {
            onChange(of: trigger) { _ in
                switch kind {
                case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .selection: UISelectionFeedbackGenerator().selectionChanged()
                }
            }
        }
    }

    /// Half-height sheet with a grabber (full height on iOS 15).
    @ViewBuilder
    func mediumSheet() -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        } else {
            self
        }
    }

}

enum HapticKind { case success, selection }

// MARK: - Share

/// System share button. The share sheet is presented straight from UIKit (the top view
/// controller), not from inside SwiftUI: on iOS 15–16 a share sheet or menu presented from
/// this app's SwiftUI hierarchy was drawn mirrored (Arabic text backwards).
struct ShareButton<Label: View>: View {
    let urls: [URL]
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button { ShareCenter.present(urls) } label: { label() }
    }
}

@MainActor
enum ShareCenter {
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let top = topViewController() else { return }
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {         // iPad: anchor to the middle of the screen
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(vc, animated: true)
    }

    /// The app / the Share Extension tell us their root view controller (UIApplication isn't
    /// available in an extension).
    static var root: () -> UIViewController? = { nil }

    static func topViewController() -> UIViewController? {
        var top = root()
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}

// MARK: - Action menu

/// The app's own menu (a card that slides up from the bottom), used instead of system menus and
/// context menus: those were drawn mirrored on iOS 15–16 in this app.
struct ActionItem: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
}

@MainActor
final class ActionMenuCenter: ObservableObject {
    static let shared = ActionMenuCenter()
    struct Menu: Identifiable { let id = UUID(); let title: String?; let items: [ActionItem] }
    @Published var menu: Menu?
    func show(_ title: String? = nil, _ items: [ActionItem]) {
        guard !items.isEmpty else { return }
        menu = Menu(title: title, items: items)
    }
}

extension View {
    /// Shows the action menu requested anywhere below (via `ActionMenuCenter.shared.show`).
    func actionMenuHost() -> some View { modifier(ActionMenuHost()) }
}

private struct ActionMenuHost: ViewModifier {
    @ObservedObject private var center = ActionMenuCenter.shared

    func body(content: Content) -> some View {
        content.overlay {
            if let menu = center.menu {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                    VStack(spacing: 10) {
                        VStack(spacing: 0) {
                            if let title = menu.title {
                                Text(title)
                                    .font(.toa(.footnote, .semibold))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity)
                                Divider()
                            }
                            ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                Button {
                                    close()
                                    DispatchQueue.main.async { item.action() }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.symbol).frame(width: 24)
                                        Text(item.title)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.toa(.body, .semibold))
                                    .foregroundStyle(item.destructive ? Theme.error : Theme.ink)
                                    .padding(.horizontal, 18)
                                    .frame(minHeight: 52)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surfaceRaised))
                        Button(action: close) {
                            Text("إلغاء")
                                .font(.toa(.body, .bold))
                                .foregroundStyle(Theme.green)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surfaceRaised))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: 480)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .haptic(.selection, trigger: menu.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: center.menu?.id)
    }

    private func close() { center.menu = nil }
}

// MARK: - Paste

/// Paste images from the clipboard. iOS 16+: the system PasteButton (no permission prompt).
/// iOS 15: a regular button reading the clipboard (iOS 15 doesn't ask permission).
struct PasteImagesButton: View {
    let onPaste: ([NSItemProvider]) -> Void

    var body: some View {
        if #available(iOS 16.0, *) {
            PasteButton(supportedContentTypes: [.image], payloadAction: onPaste)
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
        } else {
            Button {
                let providers = UIPasteboard.general.itemProviders.filter {
                    $0.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .image) == true }
                }
                if !providers.isEmpty { onPaste(providers) }
            } label: {
                Label("لصق", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Pixel placement

/// Image canvases place pixels at physical screen positions. In the app's right-to-left layout
/// SwiftUI mirrors `.position` horizontally (images themselves are never mirrored), so a canvas
/// converts its left-origin x through this instead of overriding the layout direction — an
/// override makes iOS 15–16 draw neighbouring lists and the share sheet mirrored.
struct PhysicalX {
    let direction: LayoutDirection
    let width: CGFloat
    func callAsFunction(_ x: CGFloat) -> CGFloat { direction == .rightToLeft ? width - x : x }
}
