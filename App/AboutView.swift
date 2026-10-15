//
//  AboutView.swift
//  Image Cleaner — TOA
//

import SwiftUI


struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.3"
        return "\u{2066}v\(v)\u{2069}"
    }

    var body: some View {
        SheetScaffold(title: "عن التطبيق", onDone: { dismiss() }) {
            VStack(spacing: 12) {
                AppMark(size: 110)
                Text("سنع")
                    .font(.toa(.title2, .bold))
                    .foregroundStyle(Theme.green)
                Text("\u{2066}Sana3\u{2069}")
                    .font(.toa(.footnote, .semibold))
                    .foregroundStyle(Theme.goldInk)
                Text("نظّف، افحص، وعدّل صورك")
                    .font(.toa(.subheadline))
                    .foregroundStyle(Theme.inkSecondary)
                Text("الإصدار \(version)")
                    .font(.toa(.caption))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            ToolSection("الحقوق") {
                HStack {
                    Text("الفكرة والتطوير")
                    Spacer()
                    Text(Credits.owner).foregroundStyle(Theme.inkSecondary)
                }
                Divider()
                link("إكس (تويتر)", "XLogo", "@\(Credits.xHandle)", Credits.xURL)
                Divider()
                link("سناب شات", "SnapLogo", Credits.snapHandle, Credits.snapURL)
                Divider()
                link("قيت هب", "GitHubLogo", Credits.githubHandle, Credits.githubURL)
            }

            Text(Credits.copyright)
                .font(.toa(.footnote))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity)
        }
        .tint(Theme.green)
        .font(.toa())
    }

    private func link(_ title: String, _ logo: String, _ handle: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(logo).resizable().frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                Text("\u{2066}\(handle)\u{2069}").foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}
