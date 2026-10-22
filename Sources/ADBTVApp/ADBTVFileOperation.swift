import ADBClientCore
import Foundation

enum ADBTVFileTransferTimeout {
    static func run<Result: Sendable>(
        totalTimeout: ADBTVOperationTimeout = ADBTVOperationTimeoutPolicy.fileTransfer,
        stallSeconds: Int = ADBTVOperationTimeoutPolicy.fileTransferStall.seconds,
        _ work: @escaping @Sendable (ADBTVFileTransferActivity) async throws -> Result
    ) async throws -> Result {
        let activity = ADBTVFileTransferActivity(stallSeconds: stallSeconds)
        return try await totalTimeout.run(operation: .fileTransfer) {
            try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask { try await work(activity) }
                group.addTask { try await activity.waitUntilStalled() }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                return result
            }
        }
    }
}

actor ADBTVFileTransferActivity {
    private let stallSeconds: Int
    private let clock = ContinuousClock()
    private var lastProgress = ContinuousClock.now

    init(stallSeconds: Int) {
        self.stallSeconds = stallSeconds
    }

    func recordProgress() {
        lastProgress = clock.now
    }

    func waitUntilStalled<Result>() async throws -> Result {
        while true {
            try Task.checkCancellation()
            let remaining = lastProgress.advanced(by: .seconds(stallSeconds)) - clock.now
            guard remaining > .zero else {
                throw ADBTVOperationTimeoutError.timedOut(
                    operation: .fileTransferStall,
                    seconds: stallSeconds
                )
            }
            try await Task.sleep(for: remaining)
        }
    }
}

enum ADBTVFileStagingCleanup {
    static func run(
        timeout: ADBTVOperationTimeout = ADBTVOperationTimeoutPolicy.fileStagingCleanup,
        _ cleanup: @escaping @Sendable () async throws -> Void
    ) async -> String? {
        // Cleanup must outlive cancellation of the operation that owns it.
        await Task.detached {
            do {
                try await timeout.run(operation: .fileStagingCleanup, cleanup)
                return nil as String?
            } catch {
                return String(describing: error)
            }
        }.value
    }
}

actor ADBTVFileUploadCleanupRecorder {
    private(set) var failure: ADBSharedStorageUploadCleanupError?

    func record(path: ADBSharedStoragePath, error: String?) {
        if let error {
            failure = ADBSharedStorageUploadCleanupError(
                temporaryPath: path,
                underlyingError: "The upload was interrupted.",
                cleanupError: error
            )
        }
    }
}
