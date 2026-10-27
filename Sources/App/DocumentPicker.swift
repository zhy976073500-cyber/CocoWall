import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// System document picker (UIKit) used instead of SwiftUI's fileImporter:
/// on iOS 26/27 the SwiftUI importer left unknown-UTI files (e.g. .tendies
/// carrying a dynamic type) greyed out even with broad allowed types, while
/// UIDocumentPickerViewController with .item + asCopy selects them fine.
/// Picked files arrive as local copies, so no security-scope handling.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
