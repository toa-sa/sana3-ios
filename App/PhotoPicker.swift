//
//  PhotoPicker.swift
//  Image Cleaner — TOA
//
//  The system photo picker (works from iOS 14, no library permission needed). `.current` asks
//  for the file exactly as stored — original format, size and name — never a converted copy.
//

import SwiftUI
import PhotosUI

struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 50
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([NSItemProvider]) -> Void
        init(onPick: @escaping ([NSItemProvider]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            if !results.isEmpty { onPick(results.map(\.itemProvider)) }
        }
    }
}
