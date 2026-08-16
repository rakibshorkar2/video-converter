import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DocumentPicker: UIViewControllerRepresentable {

    let contentTypes: [UTType]
    var allowsMultipleSelection = true
    let onPicked: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    static var videoContentTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .mpeg]
        if FormatCapabilities.isFFmpegEnabled {
            types.append(UTType(importedAs: "org.webmproject.webm"))
            types.append(UTType(importedAs: "org.matroska.mkv"))
            types.append(UTType(importedAs: "public.avi"))
        }
        return types
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPicked(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}