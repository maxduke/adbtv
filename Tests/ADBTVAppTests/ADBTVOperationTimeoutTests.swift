import XCTest
@testable import ADBTVApp

final class ADBTVOperationTimeoutTests: XCTestCase {
    func testRunReturnsCompletedOperationResult() async throws {
        let timeout = ADBTVOperationTimeout(seconds: 60)

        let result = try await timeout.run(operation: .remoteAction) {
            "complete"
        }

        XCTAssertEqual(result, "complete")
    }

    func testRunThrowsOperationSpecificTimeout() async {
        let timeout = ADBTVOperationTimeout(
            seconds: 60,
            sleep: { _ in }
        )

        do {
            _ = try await timeout.run(operation: .manualDeviceVerification) {
                try await Task.sleep(for: .seconds(60))
                return "unexpected"
            }
            XCTFail("Expected the operation to time out.")
        } catch let error as ADBTVOperationTimeoutError {
            XCTAssertEqual(
                error,
                .timedOut(operation: .manualDeviceVerification, seconds: 60)
            )
        } catch {
            XCTFail("Expected ADBTVOperationTimeoutError, got \(error).")
        }
    }

    func testRunPropagatesOperationFailure() async {
        let expectedError = TestOperationError.failed
        let timeout = ADBTVOperationTimeout(seconds: 60)

        do {
            let _: String = try await timeout.run(operation: .pairing) {
                throw expectedError
            }
            XCTFail("Expected the operation to fail.")
        } catch let error as TestOperationError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Expected TestOperationError, got \(error).")
        }
    }

    func testWaitUntilTimedOutIdentifiesConnectionServiceDiscovery() async {
        let timeout = ADBTVOperationTimeout(
            seconds: 45,
            sleep: { _ in }
        )

        do {
            try await timeout.waitUntilTimedOut(operation: .connectionServiceDiscovery)
        } catch let error as ADBTVOperationTimeoutError {
            XCTAssertEqual(
                error,
                .timedOut(operation: .connectionServiceDiscovery, seconds: 45)
            )
        } catch {
            XCTFail("Expected ADBTVOperationTimeoutError, got \(error).")
        }
    }

    func testWaitUntilTimedOutIdentifiesPairingServiceDiscovery() async {
        let timeout = ADBTVOperationTimeout(
            seconds: 45,
            sleep: { _ in }
        )

        do {
            try await timeout.waitUntilTimedOut(operation: .pairingServiceDiscovery)
        } catch let error as ADBTVOperationTimeoutError {
            XCTAssertEqual(
                error,
                .timedOut(operation: .pairingServiceDiscovery, seconds: 45)
            )
        } catch {
            XCTFail("Expected ADBTVOperationTimeoutError, got \(error).")
        }
    }

    func testStagingCleanupHasDedicatedBoundedTimeout() async {
        let timeout = ADBTVOperationTimeout(
            seconds: 45,
            sleep: { _ in }
        )

        do {
            try await timeout.waitUntilTimedOut(operation: .apkStagingCleanup)
        } catch let error as ADBTVOperationTimeoutError {
            XCTAssertEqual(
                error,
                .timedOut(operation: .apkStagingCleanup, seconds: 45)
            )
        } catch {
            XCTFail("Expected ADBTVOperationTimeoutError, got \(error).")
        }
    }
}

private enum TestOperationError: Error, Equatable {
    case failed
}
