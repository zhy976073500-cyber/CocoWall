//
//  DocumentPickerView.swift
//  TendiesPreview (Phase 0 probe)
//
//  UIKit document picker, mirroring CocoWall's TendiesDocumentPickerView.
//
//  Why not SwiftUI .fileImporter: Sage hit this exact bug on CocoWall #9 —
//  on his iOS, .tendies files carry an unrecognised / dynamic UTI (the
//  Files app shows them with a "?" icon), and SwiftUI's fileImporter
//  greys them out no matter how the allowed content types are widened
//  ([.item, .data] included). UIDocumentPickerViewController with
//  asCopy does not have that problem: it copies the picked file into the
//  app sandbox and hands over a plain URL.
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var contentTypes: [UTType] = []
        if let customType = UTType("com.coco.tendies") {
            contentTypes.append(customType)
        }
        if let extType = UTType(filenameExtension: "tendies") {
            contentTypes.append(extType)
        }
        contentTypes.append(contentsOf: [.archive, .zip, .data, .item])

        // asCopy: true ensures iOS safely copies documents into the app
        // sandbox tmp directory.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView

        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            parent.onPick(urls)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
