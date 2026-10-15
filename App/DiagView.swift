//
//  DiagView.swift — test builds only (compiled with -D DIAG), never in a release.
//  Shows what the system reports about language / direction, next to a Form row and a
//  segmented picker, so a screenshot from an old iOS shows which parts render mirrored.
//

#if DIAG
import SwiftUI
import UIKit

struct DiagView: View {
    @Environment(\.layoutDirection) private var direction
    @State private var pick = 0

    private var lines: [String] {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        return [
            "iOS \(UIDevice.current.systemVersion)",
            "langs \(Locale.preferredLanguages.prefix(3).joined(separator: ","))",
            "bundle \(Bundle.main.preferredLocalizations.joined(separator: ",")) / \(Bundle.main.localizations.joined(separator: ","))",
            "app \(UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? "RTL" : "LTR")",
            "swiftui \(direction == .rightToLeft ? "RTL" : "LTR")",
            "window \(window?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? "RTL" : "LTR") trait \(window?.traitCollection.layoutDirection == .rightToLeft ? "RTL" : "LTR")",
            "semantic \(window?.semanticContentAttribute.rawValue ?? -1)",
        ]
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(lines, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
            Form {
                Text("سطر قائمة عربي 123")
                Picker("", selection: $pick) {
                    Text("أول").tag(0)
                    Text("ثاني").tag(1)
                }
                .pickerStyle(.segmented)
            }
            .frame(height: 150)
        }
        .padding(6)
        .background(Color.yellow.opacity(0.25))
    }
}
#endif
