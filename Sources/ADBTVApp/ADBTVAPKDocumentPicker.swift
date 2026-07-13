#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ADBTVAPKDocumentPicker: UIViewControllerRepresentable {
    typealias Completion = (Result<URL, Error>) -> Void

    var completion: Completion

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: Completion

        init(completion: @escaping Completion) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                return
            }
            completion(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
#endif
