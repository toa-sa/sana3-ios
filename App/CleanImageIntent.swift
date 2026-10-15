//
//  CleanImageIntent.swift
//  Image Cleaner — TOA
//
//  Siri / Shortcuts: "نظّف هذي الصورة". The image comes in from the shortcut (or the share
//  sheet / a previous action), so the app never needs read access to the photo library.
//

import AppIntents
import Foundation
import UniformTypeIdentifiers

@available(iOS 18.0, *)
struct CleanImageIntent: AppIntent {
    static let title: LocalizedStringResource = "نظّف الصورة"
    static let description = IntentDescription("يشيل البيانات المخفية من الصورة ويفحصها، ويرجّع نسخة نظيفة بنفس الجودة.")

    @Parameter(title: "الصورة", supportedContentTypes: [.image])
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("نظّف \(\.$image)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        CleanerCore.maxInputBytes = 60_000_000      // Siri / Shortcuts run with less memory
        let data = image.data
        let name = image.filename
        let result: CleanResult
        do {
            result = try CleanerCore.clean(data, originalName: name)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "ما قدرت أنظّف الصورة"
            throw CleanIntentError(message: message)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        let outName = "IMG_\(f.string(from: Date()))_001.\(result.fileExtension)"
        let type = UTType(filenameExtension: result.fileExtension) ?? .image
        let file = IntentFile(data: result.data, filename: outName, type: type)
        let note = result.warnings.isEmpty ? "تم التنظيف ✅" : "تم التنظيف ⚠️ \(result.warnings.joined(separator: "، "))"
        return .result(value: file, dialog: IntentDialog(stringLiteral: note))
    }
}

@available(iOS 18.0, *)
struct CleanIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

@available(iOS 18.0, *)
struct ImageCleanerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CleanImageIntent(),
                    phrases: ["نظّف صورة في \(.applicationName)",
                              "Clean a photo with \(.applicationName)"],
                    shortTitle: "نظّف الصورة",
                    systemImageName: "checkmark.shield")
    }
}
