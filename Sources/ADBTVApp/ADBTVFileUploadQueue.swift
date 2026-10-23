import ADBClientCore
import Foundation
import Observation

@MainActor
@Observable
final class ADBTVFileUploadQueue: Identifiable {
    static let maximumFileCount = 100

    enum Phase: Equatable {
        case ready, running, cancelling, finished, cancelled, failed
    }

    enum ItemState: Equatable {
        case queued, checking, uploading, conflict, uploaded, skipped, cancelled, failed
    }

    enum Decision {
        case replace, skip, cancel
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var state = ItemState.queued
        var completedByteCount: Int64 = 0
        var totalByteCount: Int64?

        var name: String { url.lastPathComponent }
        var fractionCompleted: Double? {
            guard let totalByteCount, totalByteCount > 0 else { return nil }
            return min(max(Double(completedByteCount) / Double(totalByteCount), 0), 1)
        }
    }

    enum SelectionError: Error, Equatable {
        case noFiles, tooManyFiles, invalidFile
    }

    typealias Progress = @Sendable (Int64, Int64?) async -> Void
    typealias CheckDestination = @Sendable (URL) async throws -> ADBSyncEntryKind?
    typealias Upload = @Sendable (URL, Bool, @escaping Progress) async throws -> Void

    let id = UUID()
    private(set) var items: [Item]
    private(set) var phase = Phase.ready
    private(set) var currentIndex: Int?
    private(set) var conflictKind: ADBSyncEntryKind?
    private(set) var failure: DiagnosticDetail?
    private(set) var cleanupFailed = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var decisionContinuation: CheckedContinuation<Decision, Never>?

    init(urls: [URL]) throws {
        guard !urls.isEmpty else { throw SelectionError.noFiles }
        guard urls.count <= Self.maximumFileCount else { throw SelectionError.tooManyFiles }
        for url in urls {
            guard url.isFileURL,
                  (try? ADBSharedStoragePath.root.appendingPathComponent(url.lastPathComponent)) != nil else {
                throw SelectionError.invalidFile
            }
        }
        items = urls.map { Item(url: $0) }
    }

    var isActive: Bool { phase == .ready || phase == .running || phase == .cancelling }
    var uploadedCount: Int { items.filter { $0.state == .uploaded }.count }
    var skippedCount: Int { items.filter { $0.state == .skipped }.count }
    var processedCount: Int { uploadedCount + skippedCount }
    var unfinishedCount: Int { items.count - processedCount }
    var hasConflict: Bool {
        guard let currentIndex else { return false }
        return phase == .running && items[currentIndex].state == .conflict
    }
    var canReplace: Bool { hasConflict && conflictKind == .file }

    func start(
        diagnosticContext: [String: String] = [:],
        checkDestination: @escaping CheckDestination,
        upload: @escaping Upload
    ) {
        guard phase == .ready, task == nil else { return }
        phase = .running
        task = Task {
            await run(diagnosticContext: diagnosticContext, checkDestination: checkDestination, upload: upload)
            task = nil
        }
    }

    func waitForCompletion() async {
        await task?.value
    }

    func cancel() {
        guard isActive, phase != .cancelling else { return }
        phase = task == nil ? .cancelled : .cancelling
        task?.cancel()
        resumeDecision(.cancel)
    }

    func resolveConflict(_ decision: Decision) {
        guard hasConflict else { return }
        if case .replace = decision, !canReplace { return }
        if case .cancel = decision {
            cancel()
        } else {
            resumeDecision(decision)
        }
    }

    private func resumeDecision(_ decision: Decision) {
        let continuation = decisionContinuation
        decisionContinuation = nil
        continuation?.resume(returning: decision)
    }

    private func run(
        diagnosticContext: [String: String],
        checkDestination: CheckDestination,
        upload: Upload
    ) async {
        do {
            for index in items.indices {
                try Task.checkCancellation()
                currentIndex = index
                items[index].state = .checking
                let url = items[index].url
                conflictKind = try await checkDestination(url)
                try Task.checkCancellation()
                var replacing = false
                if conflictKind != nil {
                    items[index].state = .conflict
                    let decision = await withCheckedContinuation { continuation in
                        decisionContinuation = continuation
                    }
                    try Task.checkCancellation()
                    switch decision {
                    case .replace: replacing = true
                    case .skip:
                        items[index].state = .skipped
                        continue
                    case .cancel: throw CancellationError()
                    }
                }
                conflictKind = nil
                items[index].state = .uploading
                let itemID = items[index].id
                try await upload(url, replacing) { [weak self] current, total in
                    await self?.updateProgress(itemID: itemID, current: current, total: total)
                }
                // A successful commit remains a success even if Cancel arrived
                // immediately afterward. The next iteration still checks cancellation.
                items[index].state = .uploaded
            }
            try Task.checkCancellation()
            phase = .finished
        } catch {
            cleanupFailed = error is ADBSharedStorageUploadCleanupError
            let cancelled = !cleanupFailed && (Task.isCancelled || error is CancellationError)
            if let index = currentIndex, items[index].state != .uploaded {
                items[index].state = cancelled ? .cancelled : .failed
            }
            if !cancelled {
                var context = diagnosticContext
                context["operation"] = "uploadFiles"
                context["file"] = currentIndex.map { items[$0].name } ?? "unknown"
                failure = DiagnosticDetail(
                    summary: String(describing: error),
                    context: context
                )
            }
            phase = cancelled ? .cancelled : .failed
        }
        conflictKind = nil
        resumeDecision(.cancel)
    }

    private func updateProgress(itemID: UUID, current: Int64, total: Int64?) {
        guard phase == .running, let index = currentIndex,
              items[index].id == itemID, items[index].state == .uploading else { return }
        items[index].completedByteCount = max(items[index].completedByteCount, max(current, 0))
        items[index].totalByteCount = total.flatMap { $0 >= 0 ? $0 : nil }
    }

    enum Preview: String, CaseIterable {
        case progress, conflict, blocked, finished, cancelled, failed, cancelling
    }

    static func preview(_ scenario: Preview) throws -> ADBTVFileUploadQueue {
        let queue = try ADBTVFileUploadQueue(urls: [
            URL(fileURLWithPath: "/tmp/Android-TV-diagnostics.txt"),
            URL(fileURLWithPath: "/tmp/Family-video-with-a-long-file-name-家庭影片.mp4"),
            URL(fileURLWithPath: "/tmp/update.apk")
        ])
        queue.currentIndex = 1
        queue.items[0].state = .uploaded
        queue.items[1].state = .uploading
        queue.items[1].completedByteCount = 76_000_000
        queue.items[1].totalByteCount = 842_000_000
        queue.phase = .running
        switch scenario {
        case .progress: break
        case .conflict, .blocked:
            queue.items[1].state = .conflict
            queue.conflictKind = scenario == .conflict ? .file : .directory
        case .finished:
            queue.items[1].state = .skipped
            queue.items[2].state = .uploaded
            queue.phase = .finished
        case .cancelled:
            queue.items[1].state = .cancelled
            queue.phase = .cancelled
        case .failed:
            queue.items[1].state = .failed
            queue.phase = .failed
            queue.cleanupFailed = true
            queue.failure = DiagnosticDetail(
                summary: "Upload cleanup failed: TV unreachable",
                context: ["operation": "uploadFiles", "temporaryPath": "/sdcard/.adbtv-upload-preview"]
            )
        case .cancelling:
            queue.phase = .cancelling
        }
        return queue
    }
}
