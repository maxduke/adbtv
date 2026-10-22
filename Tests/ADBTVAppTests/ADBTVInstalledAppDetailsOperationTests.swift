import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVInstalledAppDetailsOperationTests: XCTestCase {
    func testFailedPageDoesNotBlockLaterPagesAndRetryPreservesCompletedDetails() async throws {
        let packages = try makePackages(257)
        let recorder = DetailsRecorder(packages: packages, failingPackage: packages[128])
        let operation = ADBTVInstalledAppDetailsOperation { page, userID in
            try await recorder.loadPage(page, userID: userID)
        }

        let result = try await operation.load(packages, userID: 10) { page, details in
            await recorder.record(page, details: details)
        }
        await recorder.finish(result)
        let partial = await recorder.state
        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.count), [128, 128, 1])
        XCTAssertEqual(partial.details.count, 129)
        XCTAssertNotNil(partial.details[packages[256].packageName])
        XCTAssertEqual(partial.pendingDetailsPackages, Array(packages[128 ..< 256]))
        guard case .failed = partial.detailsStatus else {
            return XCTFail("Expected a visible retryable partial result.")
        }

        let retried = try await operation.load(partial.pendingDetailsPackages, userID: 10) { page, details in
            await recorder.record(page, details: details)
        }
        await recorder.finish(retried)
        let complete = await recorder.state
        let allCalls = await recorder.calls
        let userIDs = await recorder.userIDs
        XCTAssertEqual(allCalls.map(\.count), [128, 128, 1, 128])
        XCTAssertEqual(userIDs, [10, 10, 10, 10])
        XCTAssertEqual(complete.details.count, 257)
        XCTAssertEqual(complete.detailsStatus, .ready)
        XCTAssertTrue(complete.pendingDetailsPackages.isEmpty)
    }

    func testEmptyValidPageDoesNotStopRemainingPages() async throws {
        let packages = try makePackages(2)
        let recorder = DetailsRecorder(packages: packages)
        let operation = ADBTVInstalledAppDetailsOperation(pageSize: 1) { page, userID in
            _ = try await recorder.loadPage(page, userID: userID)
            return page == [packages[0]] ? [:] : details(for: page)
        }
        let result = try await operation.load(packages, userID: 10) { page, details in
            await recorder.record(page, details: details)
        }
        XCTAssertEqual(result, .complete)
        let state = await recorder.state
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotNil(state.details[packages[1].packageName])
    }

    func testMissingHelperStopsWithoutRetryingEveryPage() async throws {
        let packages = try makePackages(129)
        let recorder = DetailsRecorder(packages: packages)
        let operation = ADBTVInstalledAppDetailsOperation { page, userID in
            _ = try await recorder.loadPage(page, userID: userID)
            throw ADBTVInstalledAppError.detailsHelperUnavailable
        }
        let result = try await operation.load(packages, userID: 10) { page, details in
            await recorder.record(page, details: details)
        }
        await recorder.finish(result)
        XCTAssertEqual(result, .helperUnavailable)
        let state = await recorder.state
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(state.detailsStatus, .helperUnavailable)
        XCTAssertTrue(state.pendingDetailsPackages.isEmpty)
    }

    func testUserChangeStopsLoadingInsteadOfRetryingOtherPages() async throws {
        let packages = try makePackages(129)
        let recorder = DetailsRecorder(packages: packages)
        let operation = ADBTVInstalledAppDetailsOperation { page, userID in
            _ = try await recorder.loadPage(page, userID: userID)
            throw ADBTVInstalledAppError.activeUserChanged(expected: 10, actual: 0)
        }
        do {
            _ = try await operation.load(packages, userID: 10) { page, details in
                await recorder.record(page, details: details)
            }
            XCTFail("Expected user-change rejection.")
        } catch let error as ADBTVInstalledAppError {
            XCTAssertEqual(error, .activeUserChanged(expected: 10, actual: 0))
        }
        let calls = await recorder.calls
        let state = await recorder.state
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(state.details.isEmpty)
    }

    func testCancellationRejectsLatePageAndDoesNotStartAnotherRequest() async throws {
        let packages = try makePackages(129)
        let gate = DetailsPageGate()
        let recorder = DetailsRecorder(packages: packages)
        let operation = ADBTVInstalledAppDetailsOperation { page, userID in
            _ = try await recorder.loadPage(page, userID: userID)
            await gate.wait()
            return details(for: page)
        }
        let task = Task {
            try await operation.load(packages, userID: 10) { page, details in
                await recorder.record(page, details: details)
            }
        }
        await gate.waitUntilRequested()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {}
        let state = await recorder.state
        let calls = await recorder.calls
        XCTAssertTrue(state.details.isEmpty)
        XCTAssertEqual(calls.count, 1)
    }

    func testMetadataStateFiltersRemovedPackagesAndResetsForAnotherDevice() throws {
        let packages = try makePackages(2)
        let deviceID = ADBTVDeviceSummary.ID()
        var state = ADBTVInstalledAppsViewState(
            deviceID: deviceID, userID: 10, packages: [packages[1]]
        )
        state.pendingDetailsPackages = packages
        state.recordDetailsPage(details(for: packages), packages: packages, forActivity: false)
        XCTAssertNil(state.details[packages[0].packageName])
        XCTAssertNotNil(state.details[packages[1].packageName])
        XCTAssertTrue(state.pendingDetailsPackages.isEmpty)

        let otherDevice = state.forDevice(ADBTVDeviceSummary.ID())
        XCTAssertNil(otherDevice.userID)
        XCTAssertTrue(otherDevice.details.isEmpty)
        XCTAssertTrue(otherDevice.pendingDetailsPackages.isEmpty)
        XCTAssertEqual(otherDevice.detailsStatus, .idle)
    }

    func testCancelledActivityRefreshRetainsTheDisplayedSnapshotsUser() throws {
        let snapshot = ADBTVAppActivitySnapshot(userID: 0, apps: [], capturedAt: Date())
        var state = ADBTVInstalledAppsViewState(userID: 10, activitySnapshot: snapshot)
        state.prepareActivityRefresh()
        state.status = .ready(message: "Cancelled.")
        XCTAssertEqual(state.mode, .active)
        XCTAssertEqual(state.userID, snapshot.userID)

        state.activitySnapshot = nil
        state.prepareActivityRefresh()
        XCTAssertNil(state.userID)
    }
}

private func makePackages(_ count: Int) throws -> [ADBTVInstalledPackage] {
    try (0 ..< count).map { try ADBTVInstalledPackage(packageName: "com.example.app\($0)") }
}

private func details(for packages: [ADBTVInstalledPackage]) -> [String: ADBTVInstalledAppDetails] {
    Dictionary(uniqueKeysWithValues: packages.map {
        ($0.packageName, ADBTVInstalledAppDetails(displayName: $0.packageName))
    })
}

private actor DetailsRecorder {
    var state: ADBTVInstalledAppsViewState
    var calls: [[ADBTVInstalledPackage]] = []
    var userIDs: [Int] = []
    let failingPackage: ADBTVInstalledPackage?
    var didFail = false

    init(packages: [ADBTVInstalledPackage], failingPackage: ADBTVInstalledPackage? = nil) {
        state = ADBTVInstalledAppsViewState(userID: 10, packages: packages)
        state.pendingDetailsPackages = packages
        self.failingPackage = failingPackage
    }

    func loadPage(_ page: [ADBTVInstalledPackage], userID: Int) throws -> [String: ADBTVInstalledAppDetails] {
        calls.append(page)
        userIDs.append(userID)
        if page.first == failingPackage, !didFail {
            didFail = true
            throw ADBTVOperationTimeoutError.timedOut(operation: .installedApps, seconds: 30)
        }
        return details(for: page)
    }

    func record(_ page: [ADBTVInstalledPackage], details: [String: ADBTVInstalledAppDetails]) {
        state.recordDetailsPage(details, packages: page, forActivity: false)
    }

    func finish(_ result: ADBTVInstalledAppDetailsLoadResult) {
        state.finishDetailsLoad(result)
    }
}

private actor DetailsPageGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}
