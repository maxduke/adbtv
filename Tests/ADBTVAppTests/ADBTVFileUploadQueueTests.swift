import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

@MainActor
final class ADBTVFileUploadQueueTests: XCTestCase {
    func testSelectionRejectsEmptyNonLocalAndExcessiveFiles() async throws {
        XCTAssertThrowsError(try ADBTVFileUploadQueue(urls: [])) {
            XCTAssertEqual($0 as? ADBTVFileUploadQueue.SelectionError, .noFiles)
        }
        XCTAssertThrowsError(try ADBTVFileUploadQueue(urls: [URL(string: "https://example.com/file")!])) {
            XCTAssertEqual($0 as? ADBTVFileUploadQueue.SelectionError, .invalidFile)
        }
        XCTAssertThrowsError(try ADBTVFileUploadQueue(urls: (0...100).map { file("\($0).txt") })) {
            XCTAssertEqual($0 as? ADBTVFileUploadQueue.SelectionError, .tooManyFiles)
        }
        XCTAssertEqual(try ADBTVFileUploadQueue(urls: (0..<100).map { file("\($0).txt") }).items.count, 100)
    }

    func testUploadsRunOnceInSelectionOrderWithoutOverlap() async throws {
        let store = UploadTestStore()
        let queue = try queue(["third.txt", "first.txt", "second.txt"])
        start(queue, store: store)
        queue.start(checkDestination: { _ in XCTFail("Duplicate start"); return nil }, upload: { _, _, _ in XCTFail("Duplicate upload") })
        await queue.waitForCompletion()

        let calls = await store.uploads
        XCTAssertEqual(calls.map(\.name), ["third.txt", "first.txt", "second.txt"])
        XCTAssertEqual(calls.map(\.replacing), [false, false, false])
        XCTAssertEqual(queue.phase, .finished)
        XCTAssertEqual(queue.items.map(\.state), [.uploaded, .uploaded, .uploaded])
        XCTAssertEqual(queue.uploadedCount, 3)
        let maximumActive = await store.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }

    func testExistingRegularFilePausesAndCanBeSkipped() async throws {
        let store = UploadTestStore(existing: ["old.txt": .file])
        let queue = try queue(["old.txt", "new.txt"])
        start(queue, store: store)
        try await waitUntil { queue.hasConflict }
        XCTAssertTrue(queue.canReplace)
        XCTAssertEqual(queue.processedCount, 0)
        let before = await store.uploads
        XCTAssertTrue(before.isEmpty)

        queue.resolveConflict(.skip)
        await queue.waitForCompletion()
        let calls = await store.uploads
        XCTAssertEqual(calls.map(\.name), ["new.txt"])
        XCTAssertEqual(queue.items.map(\.state), [.skipped, .uploaded])
        XCTAssertEqual(queue.skippedCount, 1)
        XCTAssertEqual(queue.unfinishedCount, 0)
    }

    func testReplacementPermissionAppliesOnlyToOneFile() async throws {
        let store = UploadTestStore(existing: ["one.txt": .file, "two.txt": .file])
        let queue = try queue(["one.txt", "two.txt"])
        start(queue, store: store)
        try await waitUntil { queue.hasConflict }
        queue.resolveConflict(.replace)
        try await waitUntil { queue.currentIndex == 1 && queue.hasConflict }
        let first = await store.uploads
        XCTAssertEqual(first, [.init(name: "one.txt", replacing: true)])
        queue.resolveConflict(.skip)
        await queue.waitForCompletion()
        XCTAssertEqual(queue.items.map(\.state), [.uploaded, .skipped])
    }

    func testFoldersLinksAndOtherItemsCannotBeReplaced() async throws {
        for kind: ADBSyncEntryKind in [.directory, .symbolicLink, .other] {
            let store = UploadTestStore(existing: ["blocked": kind])
            let queue = try queue(["blocked"])
            start(queue, store: store)
            try await waitUntil { queue.hasConflict }
            XCTAssertFalse(queue.canReplace)
            queue.resolveConflict(.replace)
            XCTAssertTrue(queue.hasConflict)
            queue.resolveConflict(.skip)
            await queue.waitForCompletion()
            let calls = await store.uploads
            XCTAssertTrue(calls.isEmpty)
            XCTAssertEqual(queue.items[0].state, .skipped)
        }
    }

    func testSameDestinationNameInSelectionRequiresAnotherDecision() async throws {
        let store = UploadTestStore()
        let queue = try ADBTVFileUploadQueue(urls: [file("one/movie.mp4"), file("two/movie.mp4")])
        start(queue, store: store)
        try await waitUntil { queue.currentIndex == 1 && queue.hasConflict }
        XCTAssertEqual(queue.uploadedCount, 1)
        queue.resolveConflict(.skip)
        await queue.waitForCompletion()
        let calls = await store.uploads
        let checks = await store.checks
        XCTAssertEqual(calls, [.init(name: "movie.mp4", replacing: false)])
        XCTAssertEqual(checks, ["movie.mp4", "movie.mp4"])
    }

    func testCancellationBeforeStartingPreventsAllWork() async throws {
        let store = UploadTestStore()
        let queue = try queue(["one.txt", "two.txt"])
        queue.cancel()
        start(queue, store: store)
        await queue.waitForCompletion()
        let checks = await store.checks
        XCTAssertTrue(checks.isEmpty)
        XCTAssertEqual(queue.phase, .cancelled)
        XCTAssertEqual(queue.unfinishedCount, 2)
    }

    func testCancellationDuringDestinationCheckPreventsUploadAndNextFile() async throws {
        let gate = UploadTestGate()
        let store = UploadTestStore()
        let queue = try queue(["one.txt", "two.txt"])
        queue.start(checkDestination: { _ in await gate.wait(); return nil }, upload: { url, replacing, progress in
            try await store.upload(url, replacing: replacing, progress: progress)
        })
        try await waitUntil { queue.items[0].state == .checking }
        queue.cancel()
        XCTAssertEqual(queue.phase, .cancelling)
        await gate.release()
        await queue.waitForCompletion()
        let calls = await store.uploads
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(queue.items.map(\.state), [.cancelled, .queued])
        XCTAssertEqual(queue.phase, .cancelled)
    }

    func testCancellingWhilePausedEndsWithoutStartingAnotherFile() async throws {
        let store = UploadTestStore(existing: ["one.txt": .file])
        let queue = try queue(["one.txt", "two.txt"])
        start(queue, store: store)
        try await waitUntil { queue.hasConflict }
        queue.resolveConflict(.cancel)
        await queue.waitForCompletion()
        let calls = await store.uploads
        let checks = await store.checks
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(checks, ["one.txt"])
        XCTAssertFalse(queue.hasConflict)
        XCTAssertEqual(queue.phase, .cancelled)
    }

    func testCancelledTransferKeepsOwnershipUntilIndependentCleanupEnds() async throws {
        let cleanup = UploadTestGate()
        let queue = try queue(["one.txt", "two.txt"])
        queue.start(checkDestination: { _ in nil }, upload: { _, _, _ in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                let failure = await ADBTVFileStagingCleanup.run {
                    await cleanup.wait()
                    try Task.checkCancellation()
                }
                XCTAssertNil(failure)
                throw error
            }
        })
        try await waitUntil { queue.items[0].state == .uploading }
        queue.cancel()
        try await waitUntil { await cleanup.isWaiting }
        XCTAssertEqual(queue.phase, .cancelling)
        XCTAssertTrue(queue.isActive)
        XCTAssertEqual(queue.items[1].state, .queued)
        await cleanup.release()
        await queue.waitForCompletion()
        XCTAssertEqual(queue.phase, .cancelled)
        XCTAssertEqual(queue.items.map(\.state), [.cancelled, .queued])
    }

    func testCleanupFailureAfterCancellationRemainsAVisibleFailure() async throws {
        let cleanup = UploadTestGate()
        let path = try ADBSharedStoragePath.root.appendingPathComponent(".adbtv-upload-exact")
        let queue = try queue(["one.txt", "two.txt"])
        queue.start(checkDestination: { _ in nil }, upload: { _, _, _ in
            await cleanup.wait()
            throw ADBSharedStorageUploadCleanupError(
                temporaryPath: path, underlyingError: "cancelled transfer", cleanupError: "TV unreachable"
            )
        })
        try await waitUntil { queue.items[0].state == .uploading }
        queue.cancel()
        await cleanup.release()
        await queue.waitForCompletion()
        XCTAssertEqual(queue.phase, .failed)
        XCTAssertTrue(queue.cleanupFailed)
        XCTAssertTrue(queue.failure?.summary.contains(path.rawValue) == true)
        XCTAssertTrue(queue.failure?.summary.contains("TV unreachable") == true)
        XCTAssertEqual(queue.items.map(\.state), [.failed, .queued])
    }

    func testFailureStopsQueueAndKeepsCompletedResultsAndContext() async throws {
        let store = UploadTestStore(failingName: "two.txt")
        let queue = try queue(["one.txt", "two.txt", "three.txt"])
        queue.start(diagnosticContext: ["device": "TV:5555", "path": "/sdcard/Movies"], checkDestination: { url in
            await store.check(url)
        }, upload: { url, replacing, progress in
            try await store.upload(url, replacing: replacing, progress: progress)
        })
        await queue.waitForCompletion()
        let calls = await store.uploads
        XCTAssertEqual(calls.map(\.name), ["one.txt", "two.txt"])
        XCTAssertEqual(queue.phase, .failed)
        XCTAssertEqual(queue.items.map(\.state), [.uploaded, .failed, .queued])
        XCTAssertEqual(queue.uploadedCount, 1)
        XCTAssertEqual(queue.unfinishedCount, 2)
        XCTAssertEqual(queue.failure?.context["file"], "two.txt")
        XCTAssertEqual(queue.failure?.context["device"], "TV:5555")
        XCTAssertEqual(queue.failure?.context["path"], "/sdcard/Movies")
    }

    func testDestinationCheckFailureStopsWithoutSendingAnyFile() async throws {
        let store = UploadTestStore()
        let queue = try queue(["one.txt", "two.txt"])
        queue.start(checkDestination: { _ in throw UploadTestError.failed }, upload: { url, replacing, progress in
            try await store.upload(url, replacing: replacing, progress: progress)
        })
        await queue.waitForCompletion()
        let calls = await store.uploads
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(queue.phase, .failed)
        XCTAssertEqual(queue.items.map(\.state), [.failed, .queued])
    }

    func testLateProgressCannotChangeTheNextFileOrCompletedResults() async throws {
        let callbacks = UploadTestCallbacks()
        let gate = UploadTestGate()
        let queue = try queue(["one.txt", "two.txt"])
        queue.start(checkDestination: { _ in nil }, upload: { url, _, progress in
            if url.lastPathComponent == "one.txt" {
                await callbacks.save(progress)
                await progress(5, 10)
            } else {
                await gate.wait()
            }
        })
        try await waitUntil { queue.currentIndex == 1 && queue.items[1].state == .uploading }
        await callbacks.emit(99, 100)
        XCTAssertEqual(queue.items[0].completedByteCount, 5)
        XCTAssertEqual(queue.items[1].completedByteCount, 0)
        await gate.release()
        await queue.waitForCompletion()
        await callbacks.emit(100, 100)
        XCTAssertEqual(queue.items[0].completedByteCount, 5)
    }

    func testConfirmedSuccessRemainsUploadedWhenCancellationArrivesAfterCommit() async throws {
        let queue = try queue(["one.txt", "two.txt"])
        queue.start(checkDestination: { _ in nil }, upload: { _, _, _ in
            await queue.cancel()
            // The transport confirmed the commit despite concurrent cancellation.
        })
        await queue.waitForCompletion()
        XCTAssertEqual(queue.phase, .cancelled)
        XCTAssertEqual(queue.items.map(\.state), [.uploaded, .queued])
        XCTAssertEqual(queue.uploadedCount, 1)
    }

    func testProgressSupportsUnknownAndEmptySizesAndNeverMovesBackward() async throws {
        let callbacks = UploadTestCallbacks()
        let gate = UploadTestGate()
        let queue = try queue(["one.txt"])
        queue.start(checkDestination: { _ in nil }, upload: { _, _, progress in
            await callbacks.save(progress)
            await gate.wait()
        })
        try await waitUntil { await callbacks.hasProgress }
        await callbacks.emit(-1, nil)
        XCTAssertEqual(queue.items[0].completedByteCount, 0)
        XCTAssertNil(queue.items[0].fractionCompleted)
        await callbacks.emit(0, 0)
        XCTAssertNil(queue.items[0].fractionCompleted)
        await callbacks.emit(50, 100)
        XCTAssertEqual(queue.items[0].fractionCompleted, 0.5)
        await callbacks.emit(10, 100)
        XCTAssertEqual(queue.items[0].completedByteCount, 50)
        await callbacks.emit(200, 100)
        XCTAssertEqual(queue.items[0].fractionCompleted, 1)
        queue.cancel()
        await callbacks.emit(300, 300)
        XCTAssertEqual(queue.items[0].completedByteCount, 200)
        await gate.release()
        await queue.waitForCompletion()
    }

    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    private func queue(_ names: [String]) throws -> ADBTVFileUploadQueue {
        try ADBTVFileUploadQueue(urls: names.map(file))
    }

    private func start(_ queue: ADBTVFileUploadQueue, store: UploadTestStore) {
        queue.start(checkDestination: { url in await store.check(url) }, upload: { url, replacing, progress in
            try await store.upload(url, replacing: replacing, progress: progress)
        })
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Queue did not reach the expected state.")
                throw UploadTestError.failed
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum UploadTestError: Error { case failed }

private actor UploadTestStore {
    struct Call: Equatable {
        let name: String
        let replacing: Bool
    }
    private var existing: [String: ADBSyncEntryKind]
    private let failingName: String?
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var uploads: [Call] = []
    private(set) var checks: [String] = []

    init(existing: [String: ADBSyncEntryKind] = [:], failingName: String? = nil) {
        self.existing = existing
        self.failingName = failingName
    }

    func check(_ url: URL) -> ADBSyncEntryKind? {
        checks.append(url.lastPathComponent)
        return existing[url.lastPathComponent]
    }

    func upload(_ url: URL, replacing: Bool, progress: ADBTVFileUploadQueue.Progress) async throws {
        uploads.append(Call(name: url.lastPathComponent, replacing: replacing))
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if url.lastPathComponent == failingName { throw UploadTestError.failed }
        await progress(5, 10)
        await Task.yield()
        await progress(10, 10)
        existing[url.lastPathComponent] = .file
    }
}

private actor UploadTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor UploadTestCallbacks {
    private var progress: ADBTVFileUploadQueue.Progress?
    var hasProgress: Bool { progress != nil }
    func save(_ progress: @escaping ADBTVFileUploadQueue.Progress) { self.progress = progress }
    func emit(_ current: Int64, _ total: Int64?) async { await progress?(current, total) }
}
