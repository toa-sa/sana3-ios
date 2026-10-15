//
//  ImageCleanerApp.swift
//  Image Cleaner — TOA
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct ImageCleanerApp: App {
    init() {
        Theme.applyAppearance()
        ImageTools.pixelLimit = 60_000_000          // tools decode at full size: keep memory safe
        CleanSession.removeTemporaryFiles()         // nothing from an earlier session stays on disk
        ShareCenter.root = {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
            return window?.rootViewController
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

struct HomeView: View {
    @StateObject private var session = CleanSession()
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showAbout = false
    @State private var shareAfterPick = false
    @AppStorage("welcomeSeen.v1") private var welcomeSeen = false

    var body: some View {
        WorkspaceView(session: session,
                      onAddPhotos: { shareAfterPick = false; showPhotos = true },
                      onAddFiles: { shareAfterPick = false; showFiles = true },
                      onCleanAndShare: { shareAfterPick = true; showPhotos = true },
                      onReceive: { providers in Task { await loadFromProviders(providers) } },
                      onAbout: { showAbout = true })
            .onValueChange(of: session.autoShareURLs) { urls in
                if !urls.isEmpty { ShareCenter.present(urls) }
            }
            .fullScreenCover(isPresented: Binding(get: { !welcomeSeen }, set: { welcomeSeen = !$0 })) {
                WelcomeView { welcomeSeen = true }
            }
            .sheet(isPresented: $showPhotos) {
                PhotoPicker { providers in
                    let share = shareAfterPick
                    shareAfterPick = false
                    Task { await loadFromProviders(providers, fromLibrary: true, share: share) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showFiles) {
                DocumentPicker { urls in
                    Task { await loadFromFiles(urls) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showAbout) { AboutView() }
    }

    /// Photo library, drag-and-drop and paste: the first registered image type = the original file bytes.
    @MainActor
    private func loadFromProviders(_ providers: [NSItemProvider], fromLibrary: Bool = false, share: Bool = false) async {
        var inputs: [CleanInput] = []
        for (k, provider) in providers.enumerated() {
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
            else { continue }
            let ext = UTType(type)?.preferredFilenameExtension ?? ""
            let name = provider.suggestedName.map { ext.isEmpty ? $0 : "\($0).\(ext)" }
                ?? (fromLibrary ? "صورة \(k + 1) من المكتبة" : "صورة \(k + 1)")
            let data: Data? = await withCheckedContinuation { c in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { d, _ in c.resume(returning: d) }
            }
            if let data {
                inputs.append(CleanInput(data: data, name: ext.isEmpty ? nil : "image.\(ext)", displayName: name))
            } else {
                session.addFailure(name, "ما قدرت أقرأ الصورة")
            }
        }
        if share {
            await session.processAndShare(inputs)
        } else {
            await session.process(inputs)
        }
    }

    @MainActor
    private func loadFromFiles(_ urls: [URL]) async {
        // The picker hands over local copies (asCopy), so a plain read works for every provider.
        let loaded = await Task.detached(priority: .userInitiated) { () -> [(URL, Data?, String?)] in
            urls.map { url in
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access { url.stopAccessingSecurityScopedResource() }
                    try? FileManager.default.removeItem(at: url)      // our private copy; the original is untouched
                }
                do { return (url, try Data(contentsOf: url), nil) }
                catch { return (url, nil, error.localizedDescription) }
            }
        }.value
        var inputs: [CleanInput] = []
        for (url, data, error) in loaded {
            if let data {
                inputs.append(CleanInput(data: data, name: url.lastPathComponent, displayName: url.lastPathComponent))
            } else {
                session.addFailure(url.lastPathComponent, "ما قدرت أقرأ الملف" + (error.map { " (\($0))" } ?? ""))
            }
        }
        await session.process(inputs)
    }
}
