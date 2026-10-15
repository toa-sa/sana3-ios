//
//  Theme.swift
//  Image Cleaner — TOA
//
//  TOA visual identity (shared by TOA, TOA Digital and TOA Visits):
//  colours from toa-colors.json, Arabic type in Cairo.
//

import SwiftUI
import UIKit

enum Credits {
    static let owner = "Turki Bin Obaid"
    static let xHandle = "iturk88"
    static let snapHandle = "Ngim"
    static let xURL = URL(string: "https://x.com/iturk88")!
    static let snapURL = URL(string: "https://www.snapchat.com/add/Ngim")!
    static let githubHandle = "toa-sa"
    static let githubURL = URL(string: "https://github.com/toa-sa")!
    static let copyright = "© 2026 Turki Bin Obaid — جميع الحقوق محفوظة"
}

enum Theme {
    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    // Brand
    static let green = hex(0x0D3B2E)          // Primary UI Green
    static let gold = hex(0xC79A2E)           // Brand Gold (accents, not running text on light)
    static let goldInk = hex(0x8A6A1E)        // Gold for text on light surfaces
    // Neutral
    static let ink = hex(0x1F2A27)
    static let inkSecondary = hex(0x5B6663)
    static let surface = hex(0xFAFAF7)
    static let surfaceRaised = Color.white
    static let surfaceSunken = hex(0xF2F3EF)
    static let border = hex(0xE2E5E0)
    static let ivory = hex(0xFCF9F2)
    static let cream = ivory
    // Functional
    static let success = hex(0x1E7A4F)
    static let warning = hex(0xB45309)
    static let error = hex(0xB42318)
    static let info = hex(0x2B5F8A)
    // Tinted badge backgrounds
    static let successBg = hex(0xE6F2EB)
    static let warningBg = hex(0xFCEFE3)
    static let errorBg = hex(0xFBE9E7)

    static let uiGreen = UIColor(red: 13 / 255, green: 59 / 255, blue: 46 / 255, alpha: 1)
    static let uiInk = UIColor(red: 31 / 255, green: 42 / 255, blue: 39 / 255, alpha: 1)

    /// UIKit parts SwiftUI does not style (navigation bars, segmented controls).
    static func applyAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.titleTextAttributes = [.font: UIFont.cairo(17, .bold), .foregroundColor: uiInk]
        nav.largeTitleTextAttributes = [.font: UIFont.cairo(32, .bold), .foregroundColor: uiGreen]
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.font: UIFont.cairo(16, .semibold)]
        nav.buttonAppearance = button
        nav.doneButtonAppearance = button
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let seg = UISegmentedControl.appearance()
        seg.setTitleTextAttributes([.font: UIFont.cairo(14, .semibold)], for: .normal)
        seg.selectedSegmentTintColor = .white
    }
}

extension UIFont {
    static func cairo(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let name = weight == .bold || weight == .heavy || weight == .black ? "Cairo-Bold"
            : weight == .semibold || weight == .medium ? "Cairo-SemiBold" : "Cairo-Regular"
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    /// Cairo at the size of a system text style; scales with Dynamic Type.
    static func toa(_ style: Font.TextStyle = .body, _ weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 32
        case .title: size = 26
        case .title2: size = 22
        case .title3: size = 20
        case .headline: size = 17
        case .subheadline: size = 15
        case .callout: size = 16
        case .footnote: size = 13
        case .caption: size = 12.5
        case .caption2: size = 11.5
        default: size = 16
        }
        let name = weight == .bold || weight == .heavy || weight == .black ? "Cairo-Bold"
            : weight == .semibold || weight == .medium ? "Cairo-SemiBold" : "Cairo-Regular"
        return .custom(name, size: size, relativeTo: style)
    }
}

/// Small rounded status badge in the TOA UI style.
struct StatusBadge: View {
    enum Kind { case success, warning, error, info }
    let kind: Kind
    let text: String
    var symbol: String? = nil

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol ?? defaultSymbol)
        }
        .font(.toa(.caption, .semibold))
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(bg, in: Capsule())
    }

    private var defaultSymbol: String {
        switch kind {
        case .success: return "checkmark.seal.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }
    private var fg: Color {
        switch kind {
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .error: return Theme.error
        case .info: return Theme.info
        }
    }
    private var bg: Color {
        switch kind {
        case .success: return Theme.successBg
        case .warning: return Theme.warningBg
        case .error: return Theme.errorBg
        case .info: return Color(red: 231 / 255, green: 239 / 255, blue: 246 / 255)
        }
    }
}
