//
//  ShareViewController.swift
//  Image Cleaner — Share Extension
//
//  Photos / Files / any app -> Share -> Image Cleaner
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private lazy var session = CleanSession()

    override func viewDidLoad() {
        super.viewDidLoad()
        ShareCenter.root = { [weak self] in self }
        Theme.applyAppearance()
        // The extension has ~120 MB of memory: tighter limits than the app.
        ImageTools.pixelLimit = 24_000_000
        CleanerCore.maxInputBytes = 40_000_000
        CleanSession.removeTemporaryFiles()
        let root = ExtensionRootView(session: session) { [weak self] in
            CleanSession.removeTemporaryFiles()
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        Task { await loadInputs() }
    }

    private func loadInputs() async {
        let extensionItems = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        var found = 0
        for (k, provider) in providers.enumerated() {
            // Use the first registered image type = the original file, never a converted UIImage
            guard let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) else { continue }
            let ext = UTType(type)?.preferredFilenameExtension ?? ""
            let display = provider.suggestedName ?? "صورة \(k + 1)"
            found += 1
            // One image at a time: only one file is ever in memory.
            if let data = await loadData(provider, type) {
                await session.process([CleanInput(data: data, name: ext.isEmpty ? nil : "image.\(ext)", displayName: display)])
            } else {
                session.addFailure(display, "ما قدرت أقرأ الصورة")
            }
        }
        if found == 0 && session.items.isEmpty {
            session.statusMessage = "ما لقيت صور في اللي شاركته"
        }
    }

    private func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

struct ExtensionRootView: View {
    @ObservedObject var session: CleanSession
    let onDone: () -> Void

    var body: some View {
        WorkspaceView(session: session, onDone: onDone)
    }
}
