#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ADBTVDocumentPicker: UIViewControllerRepresentable {
    typealias Completion = (Result<[URL], Error>) -> Void

    var allowsMultipleSelection = false
    var allowedContentTypes: [UTType] = [.item]
    var completion: Completion

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
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
            guard !urls.isEmpty else { return }
            completion(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

typealias ADBTVAPKDocumentPicker = ADBTVDocumentPicker
#endif
