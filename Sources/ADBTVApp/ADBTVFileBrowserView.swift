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
    @State private var query = ADBTVFileBrowserQuery()
    @State private var status = ADBTVFileListStatus.idle
    @State private var operationTask: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var transfer: ADBTVFileTransferState?
    @State private var isImporterPresented = false
    @State private var isNewFolderPromptPresented = false
    @State private var newFolderName = ""
    @State private var renameItem: ADBSharedStorageItem?
    @State private var renameName = ""
    @State private var moveItem: ADBSharedStorageItem?
    @State private var deleteItem: ADBSharedStorageItem?
    @State private var uploadQueue: ADBTVFileUploadQueue?
    @State private var isUploadQueuePresented = false
    @State private var isVisible = false
    @State private var downloadedFile: ADBTVDownloadedFile?
    @State private var downloadContainerURL: URL?

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
                            Text(adbTVLocalized("Loading files"))
                                .foregroundStyle(.secondary)
                        }
                    }
                case .ready:
                    ContentUnavailableView(
                        adbTVLocalized("Folder Is Empty"),
                        systemImage: "folder",
                        description: Text(adbTVLocalized("Upload a file or create a folder."))
                    )
                case .failed:
                    EmptyView()
                }
            } else if query.emptyState(items: items, status: status) == .noMatches {
                ContentUnavailableView {
                    Label(adbTVLocalized("No Matching Files"), systemImage: "magnifyingglass")
                } description: {
                    Text(adbTVLocalized("Try a different file name in this folder."))
                } actions: {
                    Button(adbTVLocalized("Clear Search")) { query.searchText = "" }
                }
            } else {
                Section {
                    ForEach(query.apply(to: items)) { item in
                        itemRow(item)
                    }
                }
            }
        }
        .navigationTitle(directory.adbTVDisplayName)
#if os(iOS)
        .searchable(text: $query.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: adbTVLocalized("Search This Folder"))
        .navigationBarTitleDisplayMode(.inline)
#else
        .searchable(text: $query.searchText, prompt: adbTVLocalized("Search This Folder"))
#endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isBusy, transfer == nil {
                    Button(adbTVLocalized("Cancel"), action: cancelOperation)
                        .disabled(operationTask?.isCancelled == true)
                }
                Button {
                    refreshContents()
                } label: {
                    Label(adbTVLocalized("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)

                Menu {
                    Picker(adbTVLocalized("Sort Files"), selection: $query.sortOrder) {
                        ForEach(ADBTVFileSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label(adbTVLocalized("Sort Files"), systemImage: "arrow.up.arrow.down")
                }
                .accessibilityValue(query.sortOrder.title)

                Menu {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label(adbTVLocalized("Upload Files"), systemImage: "arrow.up.doc")
                    }
                    Button {
                        newFolderName = ""
                        isNewFolderPromptPresented = true
                    } label: {
                        Label(adbTVLocalized("New Folder"), systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label(adbTVLocalized("Add"), systemImage: "plus")
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
            await refreshContentsAndWait()
        }
        .task(id: directory.rawValue) {
            await refreshContentsAndWait()
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            uploadQueue?.cancel()
            operationTask?.cancel()
            operationID = nil
            operationTask = nil
            transfer = nil
            status.finishCancelledLoad()
        }
        .filePicker(isPresented: $isImporterPresented, onDismiss: presentUploads) { result in
            switch result {
            case .success(let urls):
                selectUploads(urls)
            case .failure(let error):
                fail(adbTVLocalized("Could not open the selected files."), error: error, operation: "selectUploads")
            }
        }
        .sheet(isPresented: $isUploadQueuePresented, onDismiss: finishUploads) {
            uploadSheet
        }
        .alert(adbTVLocalized("New Folder"), isPresented: $isNewFolderPromptPresented) {
            TextField(adbTVLocalized("Folder Name"), text: $newFolderName)
            Button(adbTVLocalized("Create")) { createFolder() }
                .disabled(!canCreateFolder)
            Button(adbTVLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(adbTVLocalized("Create a folder in %@.", directory.adbTVDisplayName))
        }
        .alert(adbTVLocalized("Rename"), isPresented: renamePromptBinding) {
            TextField(adbTVLocalized("Name"), text: $renameName)
            Button(adbTVLocalized("Save")) { renameSelectedItem() }
                .disabled(!canRenameItem)
            Button(adbTVLocalized("Cancel"), role: .cancel) { renameItem = nil }
        }
        .alert(adbTVLocalized("Delete Item?"), isPresented: deletePromptBinding, presenting: deleteItem) { item in
            Button(adbTVLocalized("Delete"), role: .destructive) { delete(item) }
            Button(adbTVLocalized("Cancel"), role: .cancel) { deleteItem = nil }
        } message: { item in
            Text(item.kind == .directory
                ? adbTVLocalized("This permanently deletes \"%@\" and everything inside it.", String(describing: item.name))
                : adbTVLocalized("This permanently deletes \"%@\".", String(describing: item.name)))
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
    private var uploadSheet: some View {
        if let uploadQueue {
            let content = ADBTVFileUploadView(queue: uploadQueue, device: device, directory: directory)
#if os(iOS)
            if #available(iOS 18, *) {
                content.presentationSizing(.page)
            } else {
                content
            }
#else
            content
#endif
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ADBSharedStorageItem) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                itemLink(item)
                HStack {
                    Spacer()
                    itemActions(item)
                }
            }
        } else {
            HStack(spacing: 10) {
                itemLink(item)
                itemActions(item)
            }
        }
    }

    @ViewBuilder
    private func itemLink(_ item: ADBSharedStorageItem) -> some View {
        if item.kind == .directory {
            NavigationLink {
                ADBTVFileBrowserView(device: device, directory: item.path)
            } label: {
                itemLabel(item)
            }
            .disabled(isBusy)
        } else {
            itemLabel(item)
        }
    }

    private func itemActions(_ item: ADBSharedStorageItem) -> some View {
        Menu {
            if item.kind == .file {
                Button { download(item) } label: {
                    Label(adbTVLocalized("Download and Share"), systemImage: "arrow.down.doc")
                }
            }
            Button {
                renameName = item.name
                renameItem = item
            } label: {
                Label(adbTVLocalized("Rename"), systemImage: "pencil")
            }
            Button { moveItem = item } label: {
                Label(adbTVLocalized("Move"), systemImage: "folder")
            }
            Button(role: .destructive) { deleteItem = item } label: {
                Label(adbTVLocalized("Delete"), systemImage: "trash")
            }
        } label: {
            Label(adbTVLocalized("Actions for %@", String(describing: item.name)), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private func itemLabel(_ item: ADBSharedStorageItem) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: iconName(for: item))
                        .font(.system(size: 24))
                        .foregroundStyle(iconColor(for: item))
                        .accessibilityHidden(true)
                    Text(itemMetadata(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: item))
                    .foregroundStyle(iconColor(for: item))
                    .frame(width: 24)
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
    }

    private func transferBar(_ transfer: ADBTVFileTransferState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if transfer.showsByteCounts {
                        Text(transfer.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: cancelOperation) {
                    Label(adbTVLocalized("Cancel"), systemImage: "xmark")
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
        operationTask != nil || status == .loading || uploadQueue != nil
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

    @discardableResult
    private func refreshContents() -> Task<Void, Never>? {
        startOperation { id in
            await loadContents(operationID: id)
        }
    }

    private func refreshContentsAndWait() async {
        guard let task = refreshContents() else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func cancelOperation() {
        uploadQueue?.cancel()
        operationTask?.cancel()
        transfer?.title = adbTVLocalized("Cancelling and cleaning up")
    }

    @MainActor
    private func loadContents(operationID id: UUID) async {
        guard operationID == id, !Task.isCancelled else { return }
        status = .loading
        if ProcessInfo.processInfo.arguments.contains("--ui-files") {
            items = Self.previewItems(in: directory)
            if ProcessInfo.processInfo.arguments.contains("--ui-files-search") {
                query.searchText = ".apk"
            } else if ProcessInfo.processInfo.arguments.contains("--ui-files-no-matches") {
                query.searchText = "missing-file"
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-files-largest") {
                query.sortOrder = .largest
            }
            status = .ready
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--ui-uploads"),
               arguments.indices.contains(index + 1),
               let scenario = ADBTVFileUploadQueue.Preview(rawValue: arguments[index + 1]) {
                uploadQueue = try? ADBTVFileUploadQueue.preview(scenario)
                isUploadQueuePresented = uploadQueue != nil
            }
            return
        }
        do {
            let contents = try await Self.contents(of: directory, on: device)
            guard operationID == id, !Task.isCancelled else { return }
            items = contents
            status = .ready
        } catch {
            guard operationID == id else { return }
            if Task.isCancelled || error is CancellationError {
                status.finishCancelledLoad()
                return
            }
            fail(adbTVLocalized("Could not load this folder."), error: error, operation: "listDirectory")
        }
    }

    private func selectUploads(_ urls: [URL]) {
        guard isVisible, !isBusy else { return }
        do {
            uploadQueue = try ADBTVFileUploadQueue(urls: urls)
        } catch {
            let message = error as? ADBTVFileUploadQueue.SelectionError == .tooManyFiles
                ? adbTVLocalized("Select at most %@ files at a time.", String(ADBTVFileUploadQueue.maximumFileCount))
                : adbTVLocalized("Could not open the selected files.")
            fail(message, error: error, operation: "selectUploads")
        }
    }

    private func presentUploads() {
        guard isVisible, let uploadQueue else { return }
        isUploadQueuePresented = true
        uploadQueue.start(
            diagnosticContext: ["device": device.connectionDescription, "path": directory.rawValue],
            checkDestination: { url in
                let contents = try await Self.contents(of: directory, on: device)
                return contents.first { $0.name == url.lastPathComponent }?.kind
            },
            upload: { url, replacing, progress in
                try await Self.upload(
                    url, to: directory, on: device, replacingExisting: replacing,
                    progress: progress
                )
            }
        )
    }

    private func finishUploads() {
        guard let queue = uploadQueue else { return }
        queue.cancel()
        Task {
            await queue.waitForCompletion()
            guard uploadQueue?.id == queue.id else { return }
            uploadQueue = nil
            if isVisible, !ProcessInfo.processInfo.arguments.contains("--ui-uploads") {
                refreshContents()
            }
        }
    }

    private func download(_ item: ADBSharedStorageItem) {
        startOperation(title: adbTVLocalized("Downloading %@", String(describing: item.name)), showsByteCounts: true, operationName: "downloadFile") { id in
            let container = FileManager.default.temporaryDirectory
                .appendingPathComponent("ADBTV-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
            let destination = container.appendingPathComponent(item.name)
            do {
                try await Self.download(item, to: destination, on: device) { current, total in
                    await updateTransfer(current: current, total: total, operationID: id)
                }
                try Task.checkCancellation()
                guard operationID == id else { throw CancellationError() }
                downloadContainerURL = container
                downloadedFile = ADBTVDownloadedFile(url: destination, containerURL: container)
            } catch {
                try? FileManager.default.removeItem(at: container)
                throw error
            }
        }
    }

    private func createFolder() {
        guard canCreateFolder else { return }
        let name = normalizedNewFolderName
        startOperation(title: adbTVLocalized("Creating %@", String(describing: name)), operationName: "createDirectory") { id in
            try await Self.createDirectory(named: name, in: directory, on: device)
            await loadContents(operationID: id)
        }
    }

    private func renameSelectedItem() {
        guard let item = renameItem, canRenameItem else { return }
        let name = normalizedRenameName
        renameItem = nil
        startOperation(title: adbTVLocalized("Renaming %@", String(describing: item.name)), operationName: "renameItem") { id in
            try await Self.rename(item, to: name, on: device)
            await loadContents(operationID: id)
        }
    }

    private func move(_ item: ADBSharedStorageItem, to destination: ADBSharedStoragePath) {
        startOperation(title: adbTVLocalized("Moving %@", String(describing: item.name)), operationName: "moveItem") { id in
            try await Self.move(item, to: destination, on: device)
            await loadContents(operationID: id)
        }
    }

    private func delete(_ item: ADBSharedStorageItem) {
        deleteItem = nil
        startOperation(title: adbTVLocalized("Deleting %@", String(describing: item.name)), operationName: "deleteItem") { id in
            try await Self.delete(item, on: device)
            await loadContents(operationID: id)
        }
    }

    @discardableResult
    private func startOperation(
        title: String? = nil,
        showsByteCounts: Bool = false,
        operationName: String = "listDirectory",
        operation: @escaping @MainActor @Sendable (UUID) async throws -> Void
    ) -> Task<Void, Never>? {
        guard operationTask == nil else { return nil }
        let id = UUID()
        operationID = id
        transfer = title.map { ADBTVFileTransferState(title: $0, showsByteCounts: showsByteCounts) }
        let task = Task { @MainActor in
            defer {
                if operationID == id {
                    transfer = nil
                    operationTask = nil
                    operationID = nil
                    status.finishCancelledLoad()
                }
            }
            do {
                try await operation(id)
            } catch {
                guard operationID == id else { return }
                if error is ADBSharedStorageUploadCleanupError {
                    fail(
                        adbTVLocalized("Could not remove the upload's temporary file. See Technical Details."),
                        error: error,
                        operation: operationName
                    )
                } else if !Task.isCancelled, !(error is CancellationError) {
                    fail(adbTVLocalized("The file operation failed."), error: error, operation: operationName)
                }
            }
        }
        operationTask = task
        return task
    }

    @MainActor
    private func updateTransfer(current: Int64, total: Int64?, operationID id: UUID) {
        guard operationID == id, !Task.isCancelled else { return }
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
        if let downloadContainerURL {
            try? FileManager.default.removeItem(at: downloadContainerURL)
        }
        downloadContainerURL = nil
        downloadedFile = nil
    }

    private func itemMetadata(_ item: ADBSharedStorageItem) -> String {
        let date = item.modificationTime.formatted(date: .abbreviated, time: .shortened)
        switch item.kind {
        case .directory:
            return adbTVLocalized("Folder | %@", String(describing: date))
        case .file:
            return "\(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)) | \(date)"
        case .symbolicLink:
            return adbTVLocalized("Link | %@", String(describing: date))
        case .other:
            return adbTVLocalized("Item | %@", String(describing: date))
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
        try await ADBTVOperationTimeoutPolicy.fileListing.run(operation: .fileListing) {
            try await withConnection(to: device) { connection in
                var manager = ADBSharedStorageManager(session: connection)
                return try await manager.contents(of: directory)
            }
        }
    }

    static func upload(
        _ localURL: URL,
        to directory: ADBSharedStoragePath,
        on device: ADBTVDeviceSummary,
        replacingExisting: Bool,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws {
        let didStartAccessing = localURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { localURL.stopAccessingSecurityScopedResource() }
        }
        guard try localURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ADBSharedStorageError.notARegularFile
        }
        let cleanupRecorder = ADBTVFileUploadCleanupRecorder()
        do {
            try await ADBTVFileTransferTimeout.run { activity in
                try await withConnection(to: device) { connection in
                    var manager = ADBSharedStorageManager(session: connection)
                    _ = try await manager.upload(
                        localURL,
                        to: directory,
                        replacingExisting: replacingExisting,
                        cleanup: { path in
                            let error = await ADBTVFileStagingCleanup.run {
                                try await withConnection(to: device) { connection in
                                    var cleaner = ADBSharedStorageManager(session: connection)
                                    try await cleaner.cleanupUpload(at: path)
                                }
                            }
                            await cleanupRecorder.record(path: path, error: error)
                            return error
                        }
                    ) { event in
                        if case .progress(let current, let total) = event {
                            await activity.recordProgress()
                            await progress(Int64(current), Int64(total))
                        }
                    }
                }
            }
        } catch {
            if error is ADBSharedStorageUploadCleanupError { throw error }
            if let failure = await cleanupRecorder.failure {
                throw ADBSharedStorageUploadCleanupError(
                    temporaryPath: failure.temporaryPath,
                    underlyingError: String(describing: error),
                    cleanupError: failure.cleanupError
                )
            }
            throw error
        }
    }

    static func download(
        _ item: ADBSharedStorageItem,
        to localURL: URL,
        on device: ADBTVDeviceSummary,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws {
        try await ADBTVFileTransferTimeout.run { activity in
            try await withConnection(to: device) { connection in
                var manager = ADBSharedStorageManager(session: connection)
                _ = try await manager.download(item, to: localURL) { event in
                    if case .progress(let current, let total) = event {
                        await activity.recordProgress()
                        await progress(current, total)
                    }
                }
            }
        }
    }

    static func createDirectory(
        named name: String,
        in directory: ADBSharedStoragePath,
        on device: ADBTVDeviceSummary
    ) async throws {
        try await ADBTVOperationTimeoutPolicy.fileMutation.run(operation: .fileMutation) {
            try await withConnection(to: device) { connection in
                var manager = ADBSharedStorageManager(session: connection)
                _ = try await manager.createDirectory(named: name, in: directory)
            }
        }
    }

    static func rename(
        _ item: ADBSharedStorageItem,
        to name: String,
        on device: ADBTVDeviceSummary
    ) async throws {
        try await ADBTVOperationTimeoutPolicy.fileMutation.run(operation: .fileMutation) {
            try await withConnection(to: device) { connection in
                var manager = ADBSharedStorageManager(session: connection)
                _ = try await manager.rename(item, to: name)
            }
        }
    }

    static func move(
        _ item: ADBSharedStorageItem,
        to destination: ADBSharedStoragePath,
        on device: ADBTVDeviceSummary
    ) async throws {
        try await ADBTVOperationTimeoutPolicy.fileMutation.run(operation: .fileMutation) {
            try await withConnection(to: device) { connection in
                var manager = ADBSharedStorageManager(session: connection)
                _ = try await manager.move(item, to: destination)
            }
        }
    }

    static func delete(
        _ item: ADBSharedStorageItem,
        on device: ADBTVDeviceSummary
    ) async throws {
        try await ADBTVOperationTimeoutPolicy.fileMutation.run(operation: .fileMutation) {
            try await withConnection(to: device) { connection in
                var manager = ADBSharedStorageManager(session: connection)
                try await manager.delete(item)
            }
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
                    Button(adbTVLocalized("Cancel")) { dismiss() }
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
                    Label(adbTVLocalized("Move Here"), systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(directory == sourceDirectory || isExcluded(directory))
            }

            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(adbTVLocalized("Loading folders")).foregroundStyle(.secondary)
                    }
                }
            } else if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                Section(adbTVLocalized("Folders")) {
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
        .navigationTitle(directory.adbTVDisplayName)
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
                self.error = adbTVLocalized("Could not load folders.")
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
    var showsByteCounts = false
    var completedByteCount: Int64 = 0
    var totalByteCount: Int64?

    var fractionCompleted: Double? {
        guard let totalByteCount, totalByteCount > 0 else { return nil }
        return min(max(Double(completedByteCount) / Double(totalByteCount), 0), 1)
    }

    var detail: String {
        let completed = ByteCountFormatter.string(fromByteCount: completedByteCount, countStyle: .file)
        guard let totalByteCount else { return completed }
        return adbTVLocalized("%@ of %@", String(describing: completed), String(describing: ByteCountFormatter.string(fromByteCount: totalByteCount, countStyle: .file)))
    }
}

private enum ADBTVFileBrowserError: Error {
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
                Label(adbTVLocalized("Share File"), systemImage: "square.and.arrow.up")
            }
            Button(adbTVLocalized("Done")) {
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
        onDismiss: @escaping () -> Void,
        completion: @escaping (Result<[URL], Error>) -> Void
    ) -> some View {
#if os(iOS)
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            ADBTVDocumentPicker(allowsMultipleSelection: true) { result in
                isPresented.wrappedValue = false
                completion(result)
            }
        }
#else
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            completion(result)
            onDismiss()
        }
#endif
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
