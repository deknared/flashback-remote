import SwiftUI
import UniformTypeIdentifiers

// Wraps UIDocumentPickerViewController so the user can import DNG/JPEG files from
// the Files app — including a camera connected over USB, which appears there as a
// browsable location. Sideloaded apps can't talk to USB directly, but the system
// document picker bridges that gap.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let dngType = UTType(filenameExtension: "dng") ?? .image
        // asCopy:false gives in-place, security-scoped access to the originals so we
        // can optionally delete them after copying (the USB "copy + delete" flow).
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [dngType, .image, .data],
            asCopy: false
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
