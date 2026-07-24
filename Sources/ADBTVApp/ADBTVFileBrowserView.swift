import ADBClientCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
struct ADBTVFileBrowserView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var device: ADBTVDeviceSummary
    var directory: ADBSharedStoragePath = .root

    @State private var items: [ADBSharedStorageItem] = []
    @State private var status = ADBTVFileListStatus.idle
    @State private var operationTask: Task<Void, Never>?
    @State private var transfer: ADBTVFileTransferState?
    @State private var isImporterPresented = false
    @State private var isNewFolderPromptPresented = false
    @State private var newFolderName = ""
    @State private var renameItem: ADBSharedStorageItem?
    @State private var renameName = ""
    @State private var moveItem: ADBSharedStorageItem?
    @State private var deleteItem: ADBSharedStorageItem?
    @State private var pendingUploadURL: URL?
    @State private var downloadedFile: ADBTVDownloadedFile?

    var body: some View {
        List {
            if case .failed(let failure) = status {
                Section {
                    Label(failure.userMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    DiagnosticDisclosure(diagnosticDetail: failure.diagnosticDetail)
                }
            }

            if items.isEmpty {
                switch status {
                case .idle, .loading:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading files")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .ready:
                    ContentUnavailableView(
                        "Folder Is Empty",
                        systemImage: "folder",
                        description: Text("Upload a file or create a folder.")
                    )
                case .failed:
                    EmptyView()
                }
            } else {
                Section {
                    ForEach(items) { item in
                        itemRow(item)
                    }
                }
            }
        }
        .navigationTitle(directory.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await loadContents() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)

                Menu {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Upload File", systemImage: "arrow.up.doc")
                    }
                    Button {
                        newFolderName = ""
                        isNewFolderPromptPresented = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(isBusy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let transfer {
                transferBar(transfer)
            }
        }
        .refreshable {
            guard !isBusy else { return }
            await loadContents()
        }
        .task(id: directory.rawValue) {
            await loadContents()
        }
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
        }
        .filePicker(isPresented: $isImporterPresented) { result in
            switch result {
            case .success(let url):
                selectUpload(url)
            case .failure(let error):
                fail("Could not open the selected file.", error: error, operation: "selectUpload")
            }
        }
        .alert("New Folder", isPresented: $isNewFolderPromptPresented) {
            TextField("Folder Name", text: $newFolderName)
            Button("Create") { createFolder() }
                .disabled(!canCreateFolder)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a folder in \(directory.name).")
        }
        .alert("Rename", isPresented: renamePromptBinding) {
            TextField("Name", text: $renameName)
            Button("Save") { renameSelectedItem() }
                .disabled(!canRenameItem)
            Button("Cancel", role: .cancel) { renameItem = nil }
        }
        .alert("Delete Item?", isPresented: deletePromptBinding, presenting: deleteItem) { item in
            Button("Delete", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) { deleteItem = nil }
        } message: { item in
            Text(item.kind == .directory
                ? "This permanently deletes \"\(item.name)\" and everything inside it."
                : "This permanently deletes \"\(item.name)\".")
        }
        .alert("Replace Existing File?", isPresented: uploadReplacementBinding) {
            Button("Replace", role: .destructive) {
                if let url = pendingUploadURL {
                    upload(url)
                }
                pendingUploadURL = nil
            }
            Button("Cancel", role: .cancel) { pendingUploadURL = nil }
        } message: {
            Text("A file with this name already exists in \(directory.name).")
        }
        .sheet(item: $moveItem) { item in
            ADBTVFolderPickerView(
                device: device,
                sourceDirectory: item.path.parent ?? directory,
                excludedDirectory: item.kind == .directory ? item.path : nil
            ) { destination in
                moveItem = nil
                move(item, to: destination)
            }
        }
        .sheet(item: $downloadedFile, onDismiss: cleanupDownload) { file in
            ADBTVFileShareView(url: file.url) {
                cleanupDownload()
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ADBSharedStorageItem) -> some View {
        HStack(spacing: 10) {
            if item.kind == .directory {
                NavigationLink {
                    ADBTVFileBrowserView(device: device, directory: item.path)
                } label: {
                    itemLabel(item)
                }
            } else {
                itemLabel(item)
            }

            Menu {
                if item.kind == .file {
                    Button { download(item) } label: {
                        Label("Download and Share", systemImage: "arrow.down.doc")
                    }
                }
                Button {
                    renameName = item.name
                    renameItem = item
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { moveItem = item } label: {
                    Label("Move", systemImage: "folder")
                }
                Button(role: .destructive) { deleteItem = item } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Label("Actions for \(item.name)", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .disabled(isBusy)
        }
    }

    private func itemLabel(_ item: ADBSharedStorageItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: item))
                .foregroundStyle(iconColor(for: item))
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(itemMetadata(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func transferBar(_ transfer: ADBTVFileTransferState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(transfer.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    operationTask?.cancel()
                    self.transfer?.title = "Cancelling"
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(operationTask?.isCancelled == true)
            }
            if let fraction = transfer.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var isBusy: Bool {
        operationTask != nil || status == .loading
    }

    private var normalizedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreateFolder: Bool {
        (try? directory.appendingPathComponent(normalizedNewFolderName)) != nil
    }

    private var normalizedRenameName: String {
        renameName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRenameItem: Bool {
        guard let renameItem, normalizedRenameName != renameItem.name else { return false }
        return (try? directory.appendingPathComponent(normalizedRenameName)) != nil
    }

    private var renamePromptBinding: Binding<Bool> {
        Binding(
            get: { renameItem != nil },
            set: { if !$0 { renameItem = nil } }
        )
    }

    private var deletePromptBinding: Binding<Bool> {
        Binding(
            get: { deleteItem != nil },
            set: { if !$0 { deleteItem = nil } }
        )
    }

    private var uploadReplacementBinding: Binding<Bool> {
        Binding(
            get: { pendingUploadURL != nil },
            set: { if !$0 { pendingUploadURL = nil } }
        )
    }

    @MainActor
    private func loadContents() async {
        status = .loading
        if ProcessInfo.processInfo.arguments.contains("--ui-files") {
            items = Self.previewItems(in: directory)
            status = .ready
            return
        }
        do {
            items = try await Self.contents(of: directory, on: device)
            status = .ready
        } catch is CancellationError {
            status.finishCancelledLoad()
            return
        } catch {
            fail("Could not load this folder.", error: error, operation: "listDirectory")
        }
    }

    private func selectUpload(_ url: URL) {
        if let existing = items.first(where: { $0.name == url.lastPathComponent }) {
            guard existing.kind == .file else {
                fail(
                    "A folder with this name already exists.",
                    error: ADBTVFileBrowserError.destinationIsDirectory,
                    operation: "uploadFile"
                )
                return
            }
            pendingUploadURL = url
            return
        }
        upload(url)
    }

    private func upload(_ url: URL) {
        startOperation(title: "Uploading \(url.lastPathComponent)") {
            try await Self.upload(url, to: directory, on: device) { current, total in
                await updateTransfer(current: current, total: total)
            }
            await loadContents()
        }
    }

    private func download(_ item: ADBSharedStorageItem) {
        startOperation(title: "Downloading \(item.name)") {
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("ADBTV-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
            let destination = container.appendingPathComponent(item.name)
            do {
                try await Self.download(item, to: destination, on: device) { current, total in
                    await updateTransfer(current: current, total: total)
                }
                await MainActor.run {
                    downloadedFile = ADBTVDownloadedFile(url: destination, containerURL: container)
                }
            } catch {
                try? FileManager.default.removeItem(at: container)
                throw error
            }
        }
    }

    private func createFolder() {
        guard canCreateFolder else { return }
        let name = normalizedNewFolderName
        startOperation(title: "Creating \(name)") {
            try await Self.createDirectory(named: name, in: directory, on: device)
            await loadContents()
        }
    }

    private func renameSelectedItem() {
        guard let item = renameItem, canRenameItem else { return }
        let name = normalizedRenameName
        renameItem = nil
        startOperation(title: "Renaming \(item.name)") {
            try await Self.rename(item, to: name, on: device)
            await loadContents()
        }
    }

    private func move(_ item: ADBSharedStorageItem, to destination: ADBSharedStoragePath) {
        startOperation(title: "Moving \(item.name)") {
            try await Self.move(item, to: destination, on: device)
            await loadContents()
        }
    }

    private func delete(_ item: ADBSharedStorageItem) {
        deleteItem = nil
        startOperation(title: "Deleting \(item.name)") {
            try await Self.delete(item, on: device)
            await loadContents()
        }
    }

    private func startOperation(
        title: String,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        guard operationTask == nil else { return }
        transfer = ADBTVFileTransferState(title: title)
        operationTask = Task { @MainActor in
            do {
                try await operation()
                transfer = nil
                operationTask = nil
            } catch is CancellationError {
                transfer = nil
                operationTask = nil
            } catch {
                transfer = nil
                operationTask = nil
                fail("The file operation failed.", error: error, operation: title)
            }
        }
    }

    @MainActor
    private func updateTransfer(current: Int64, total: Int64?) {
        transfer?.completedByteCount = current
        transfer?.totalByteCount = total
    }

    @MainActor
    private func fail(_ userMessage: String, error: Error, operation: String) {
        status = .failed(ADBTVFileBrowserFailure(
            userMessage: userMessage,
            diagnosticDetail: DiagnosticDetail(
                summary: String(describing: error),
                context: [
                    "device": device.connectionDescription,
                    "operation": operation,
                    "path": directory.rawValue
                ]
            )
        ))
    }

    private func cleanupDownload() {
        if let downloadedFile {
            try? FileManager.default.removeItem(at: downloadedFile.containerURL)
        }
        downloadedFile = nil
    }

    private func itemMetadata(_ item: ADBSharedStorageItem) -> String {
        let date = item.modificationTime.formatted(date: .abbreviated, time: .shortened)
        switch item.kind {
        case .directory:
            return "Folder | \(date)"
        case .file:
            return "\(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)) | \(date)"
        case .symbolicLink:
            return "Link | \(date)"
        case .other:
            return "Item | \(date)"
        }
    }

    private func iconName(for item: ADBSharedStorageItem) -> String {
        switch item.kind {
        case .directory: return "folder.fill"
        case .symbolicLink: return "link"
        case .other: return "doc"
        case .file:
            let type = UTType(filenameExtension: item.path.rawValue.pathExtension)
            if type?.conforms(to: .image) == true { return "photo" }
            if type?.conforms(to: .movie) == true { return "film" }
            if type?.conforms(to: .audio) == true { return "music.note" }
            if type?.conforms(to: .archive) == true { return "archivebox" }
            return "doc.fill"
        }
    }

    private func iconColor(for item: ADBSharedStorageItem) -> Color {
        switch item.kind {
        case .directory: return .blue
        case .symbolicLink: return .teal
        case .file, .other: return .secondary
        }
    }

    private static func previewItems(in directory: ADBSharedStoragePath) -> [ADBSharedStorageItem] {
        guard directory.isRoot else { return [] }
        let values: [(String, UInt32, UInt32)] = [
            ("Download", 0o040755, 0),
            ("Movies", 0o040755, 0),
            ("Pictures", 0o040755, 0),
            ("Android-TV-diagnostics-2026-07-18.txt", 0o100644, 184_320),
            ("family-video.mp4", 0o100644, 842_000_000),
            ("update.apk", 0o100644, 48_000_000)
        ]
        return values.compactMap { name, mode, size in
            guard let path = try? directory.appendingPathComponent(name) else { return nil }
            return ADBSharedStorageItem(
                path: path,
                entry: ADBSyncDirectoryEntry(
                    name: name,
                    mode: ADBSyncFileMode(rawValue: mode),
                    byteCount: size,
                    modificationTime: 1_752_768_000
                )
            )
        }
    }
}

private extension ADBTVFileBrowserView {
    static func contents(
        of directory: ADBSharedStoragePath,
        on device: ADBTVDeviceSummary
    ) async throws -> [ADBSharedStorageItem] {
        try await withConnection(to: device) { connection in
            var manager = ADBSharedStorageManager(session: connection)
            return try await manager.contents(of: directory)
        }
    }

    static func upload(
        _ localURL: URL,
        to directory: ADBSharedStoragePath,
        on device: ADBTVDeviceSummary,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws {
        let didStartAccessing = localURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { localURL.stopAccessingSecurityScopedResource() }
        }
        try await withConnection(to: device) { connection in
            var manager = ADBSharedStorageManager(session: connection)
            _ = try await manager.upload(localURL, to: directory) { event in
                if case .progress(let current, let total) = event {
                    await progress(Int64(current), Int64(total))
                }
            }
        }
    }

    static func download(
        _ item: ADBSharedStorageItem,
        to localURL: URL,
        on device: ADBTVDeviceSummary,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws {
        try await withConnection(to: device) { connection in
            var manager = ADBSharedStorageManager(session: connection)
            _ = try await manager.download(item, to: localURL) { event in
                if case .progress(let current, let total) = event {
                    await progress(current, total)
                }
            }
        }
    }

    static func createDirectory(
        named name: String,
        in directory: ADBSharedStoragePath,
        on device: ADBTVDeviceSummary
    ) async throws {
        try await withConnection(to: device) { connection in
            var manager = ADBSharedStorageManager(session: connection)
            _ = try await manager.createDirectory(named: name, in: directory)
        }
    }

    static func rename(
        _ item: ADBSharedStorageItem,
        to name: String,
        on device: ADBTVDeviceSummary
    ) async throws {
        try await withConnection(to: device) { connection in
            var manager = ADBSharedStorageManager(session: connection)
            _ = try await manager.rename(item, to: name)
        }
    }

    static func move(
        _ item: ADBSharedStorageItem,
        to destination: ADBSharedStoragePath,
        on device: ADBTVDeviceSummary
    ) async throws {
        try await withConnection(to: device) { connection in
            var manager = ADBSharedStorageManager(session: connection)
            _ = try await manager.move(item, to: destination)
        }
    }

    static func delete(
        _ item: ADBSharedStorageItem,
        on device: ADBTVDeviceSummary
    ) async throws {
        try await withConnection(to: device) { connection in
            var manager = ADBSharedStorageManager(session: connection)
            try await manager.delete(item)
        }
    }

    static func withConnection<Result: Sendable>(
        to device: ADBTVDeviceSummary,
        operation: @escaping @Sendable (ADBDeviceConnection) async throws -> Result
    ) async throws -> Result {
#if canImport(Network) && canImport(Security)
        let connection = try await ADBTVOperationTimeoutPolicy.deviceConnection.run(
            operation: .deviceConnection
        ) {
            try await ADBDeviceConnection.connectedToWirelessDebugging(
                target: device.networkTarget()
            )
        }
        defer { connection.cancel() }
        return try await operation(connection)
#else
        throw ADBTVFileBrowserError.unsupportedPlatform
#endif
    }
}

private struct ADBTVFolderPickerView: View {
    @Environment(\.dismiss) private var dismiss

    var device: ADBTVDeviceSummary
    var sourceDirectory: ADBSharedStoragePath
    var excludedDirectory: ADBSharedStoragePath?
    var select: (ADBSharedStoragePath) -> Void

    var body: some View {
        NavigationStack {
            ADBTVFolderPickerDirectoryView(
                device: device,
                directory: .root,
                sourceDirectory: sourceDirectory,
                excludedDirectory: excludedDirectory,
                select: select
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct ADBTVFolderPickerDirectoryView: View {
    var device: ADBTVDeviceSummary
    var directory: ADBSharedStoragePath
    var sourceDirectory: ADBSharedStoragePath
    var excludedDirectory: ADBSharedStoragePath?
    var select: (ADBSharedStoragePath) -> Void

    @State private var items: [ADBSharedStorageItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button {
                    select(directory)
                } label: {
                    Label("Move Here", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(directory == sourceDirectory || isExcluded(directory))
            }

            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading folders").foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                Section("Folders") {
                    ForEach(visibleFolders) { item in
                        NavigationLink {
                            ADBTVFolderPickerDirectoryView(
                                device: device,
                                directory: item.path,
                                sourceDirectory: sourceDirectory,
                                excludedDirectory: excludedDirectory,
                                select: select
                            )
                        } label: {
                            Label(item.name, systemImage: "folder.fill")
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle(directory.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task(id: directory.rawValue) {
            do {
                items = try await ADBTVFileBrowserView.contents(of: directory, on: device)
                error = nil
            } catch is CancellationError {
                return
            } catch {
                self.error = "Could not load folders."
            }
            isLoading = false
        }
    }

    private var visibleFolders: [ADBSharedStorageItem] {
        items.filter { $0.kind == .directory && !isExcluded($0.path) }
    }

    private func isExcluded(_ path: ADBSharedStoragePath) -> Bool {
        guard let excludedDirectory else { return false }
        return path == excludedDirectory || path.isDescendant(of: excludedDirectory)
    }
}

private struct ADBTVFileTransferState: Equatable {
    var title: String
    var completedByteCount: Int64 = 0
    var totalByteCount: Int64?

    var fractionCompleted: Double? {
        guard let totalByteCount, totalByteCount > 0 else { return nil }
        return min(max(Double(completedByteCount) / Double(totalByteCount), 0), 1)
    }

    var detail: String {
        let completed = ByteCountFormatter.string(fromByteCount: completedByteCount, countStyle: .file)
        guard let totalByteCount else { return completed }
        return "\(completed) of \(ByteCountFormatter.string(fromByteCount: totalByteCount, countStyle: .file))"
    }
}

struct ADBTVFileBrowserFailure: Equatable {
    var userMessage: String
    var diagnosticDetail: DiagnosticDetail
}

enum ADBTVFileListStatus: Equatable {
    case idle
    case loading
    case ready
    case failed(ADBTVFileBrowserFailure)

    mutating func finishCancelledLoad() {
        guard self == .loading else { return }
        self = .ready
    }
}

private enum ADBTVFileBrowserError: Error {
    case destinationIsDirectory
    case unsupportedPlatform
}

private struct ADBTVDownloadedFile: Identifiable {
    let id = UUID()
    var url: URL
    var containerURL: URL
}

#if os(iOS)
private struct ADBTVFileShareView: UIViewControllerRepresentable {
    var url: URL
    var completion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                context.coordinator.completion()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    final class Coordinator {
        var completion: () -> Void

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }
    }
}
#else
private struct ADBTVFileShareView: View {
    @Environment(\.dismiss) private var dismiss
    var url: URL
    var completion: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ShareLink(item: url) {
                Label("Share File", systemImage: "square.and.arrow.up")
            }
            Button("Done") {
                completion()
                dismiss()
            }
        }
        .padding()
    }
}
#endif

private extension View {
    @ViewBuilder
    func filePicker(
        isPresented: Binding<Bool>,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> some View {
#if os(iOS)
        sheet(isPresented: isPresented) {
            ADBTVDocumentPicker { result in
                isPresented.wrappedValue = false
                completion(result)
            }
        }
#else
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result.map({ $0.first }) {
            case .success(let url?): completion(.success(url))
            case .success(nil): break
            case .failure(let error): completion(.failure(error))
            }
        }
#endif
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
