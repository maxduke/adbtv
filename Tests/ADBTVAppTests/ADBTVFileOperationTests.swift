import ADBClientCore
import XCTest
@testable import ADBTVApp

final class ADBTVFileOperationTests: XCTestCase {
    func testStalledTransferCancelsPendingWork() async {
        let cancelled = FileOperationObservation()
        do {
            let _: Bool = try await ADBTVFileTransferTimeout.run(stallSeconds: 0) { _ in
                do {
                    try await Task.sleep(for: .seconds(60))
                    return true
                } catch {
                    await cancelled.record()
                    throw error
                }
            }
            XCTFail("Expected stall timeout.")
        } catch {
            XCTAssertEqual(
                error as? ADBTVOperationTimeoutError,
                .timedOut(operation: .fileTransferStall, seconds: 0)
            )
        }
        let didCancel = await cancelled.didRun
        XCTAssertTrue(didCancel)
    }

    func testProgressExtendsTheTransferInactivityDeadline() async throws {
        let result = try await ADBTVFileTransferTimeout.run(stallSeconds: 1) { activity in
            for _ in 0 ..< 7 {
                try await Task.sleep(for: .milliseconds(200))
                await activity.recordProgress()
            }
            return "finished"
        }

        XCTAssertEqual(result, "finished")
    }

    func testTotalTimeoutStillBoundsAnActiveTransfer() async {
        let timeout = ADBTVOperationTimeout(seconds: 15, sleep: { _ in })
        do {
            let _: Bool = try await ADBTVFileTransferTimeout.run(
                totalTimeout: timeout,
                stallSeconds: 60
            ) { _ in
                try await Task.sleep(for: .seconds(60))
                return true
            }
            XCTFail("Expected total timeout.")
        } catch {
            XCTAssertEqual(
                error as? ADBTVOperationTimeoutError,
                .timedOut(operation: .fileTransfer, seconds: 15)
            )
        }
    }

    func testCancelledParentCanFinishIndependentStagingCleanup() async {
        let observation = FileOperationObservation()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ADBTVFileStagingCleanup.run {
                try Task.checkCancellation()
                await observation.record()
            }
        }.value

        XCTAssertNil(result)
        let didClean = await observation.didRun
        XCTAssertTrue(didClean)
    }

    func testStagingCleanupTimeoutIsReported() async {
        let failure = await ADBTVFileStagingCleanup.run(
            timeout: ADBTVOperationTimeout(seconds: 45, sleep: { _ in })
        ) {
            try await Task.sleep(for: .seconds(60))
        }

        XCTAssertTrue(failure?.contains("fileStagingCleanup") == true)
    }

    func testCleanupFailureRemainsAvailableAfterOuterOperationTimeout() async throws {
        let recorder = ADBTVFileUploadCleanupRecorder()
        let path = try ADBSharedStoragePath.root.appendingPathComponent(".adbtv-upload-test")
        do {
            let _: Bool = try await ADBTVOperationTimeout(seconds: 30, sleep: { _ in })
                .run(operation: .fileTransfer) {
                    do {
                        try await Task.sleep(for: .seconds(60))
                        return true
                    } catch {
                        await recorder.record(path: path, error: "TV unreachable")
                        throw error
                    }
                }
            XCTFail("Expected timeout.")
        } catch {}

        let failure = await recorder.failure
        XCTAssertEqual(failure?.temporaryPath, path)
        XCTAssertEqual(failure?.cleanupError, "TV unreachable")
    }
}

private actor FileOperationObservation {
    private(set) var didRun = false

    func record() {
        didRun = true
    }
}
