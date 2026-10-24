import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

@MainActor
final class ADBTVInstalledAppDetailsCoordinatorTests: XCTestCase {
    func testPublishesEveryCompletedPageBeforeTheFinalResult() async throws {
        let packages = try (0..<129).map { try ADBTVInstalledPackage(packageName: "com.example.app\($0)") }
        let recorder = DetailEvents()
        let calls = DetailCalls()
        let coordinator = ADBTVInstalledAppDetailsCoordinator()
        let task = coordinator.start(packages, userID: 10, loadPage: { page, userID in
            await calls.record(page, userID: userID)
            return Dictionary(uniqueKeysWithValues: page.map {
                ($0.packageName, ADBTVInstalledAppDetails(displayName: $0.packageName))
            })
        }) { recorder.record($0) }
        await task.value
        XCTAssertEqual(recorder.pageCounts, [128, 1])
        XCTAssertEqual(recorder.finished, [.complete])
        XCTAssertTrue(recorder.failureDescriptions.isEmpty)
        XCTAssertEqual(recorder.order, ["page", "page", "finished"])
        let userIDs = await calls.userIDs
        XCTAssertEqual(userIDs, [10, 10])
    }

    func testCancelRejectsAnUncooperativeLatePageAndCompletion() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.app")
        let gate = DetailGate()
        let recorder = DetailEvents()
        let coordinator = ADBTVInstalledAppDetailsCoordinator()
        let task = coordinator.start([package], userID: 0, loadPage: { _, _ in
            try await gate.load()
        }) { recorder.record($0) }
        await gate.waitUntilRequested()
        coordinator.cancel()
        await gate.succeed([package.packageName: .init(displayName: "Late")])
        await task.value
        XCTAssertTrue(recorder.order.isEmpty)
    }

    func testReplacingARequestPublishesOnlyTheNewUserAndDevicesData() async throws {
        let first = try ADBTVInstalledPackage(packageName: "com.example.old")
        let second = try ADBTVInstalledPackage(packageName: "com.example.new")
        let oldGate = DetailGate()
        let recorder = DetailEvents()
        let calls = DetailCalls()
        let coordinator = ADBTVInstalledAppDetailsCoordinator()
        let old = coordinator.start([first], userID: 0, loadPage: { page, userID in
            await calls.record(page, userID: userID)
            return try await oldGate.load()
        }) { recorder.record($0) }
        await oldGate.waitUntilRequested()
        let current = coordinator.start([second], userID: 10, loadPage: { page, userID in
            await calls.record(page, userID: userID)
            return [second.packageName: .init(displayName: "Current TV")]
        }) { recorder.record($0) }
        await current.value
        await oldGate.succeed([first.packageName: .init(displayName: "Previous TV")])
        await old.value
        XCTAssertEqual(recorder.packageNames, [[second.packageName]])
        XCTAssertEqual(recorder.finished, [.complete])
        XCTAssertEqual(recorder.order, ["page", "finished"])
        let userIDs = await calls.userIDs
        XCTAssertEqual(userIDs, [0, 10])
    }

    func testOldCompletionCannotClearTheReplacementTaskBeforeItsCancellation() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.app")
        let oldGate = DetailGate()
        let currentGate = DetailGate()
        let recorder = DetailEvents()
        let coordinator = ADBTVInstalledAppDetailsCoordinator()
        let old = coordinator.start([package], userID: 0, loadPage: { _, _ in
            try await oldGate.load()
        }) { recorder.record($0) }
        await oldGate.waitUntilRequested()
        let current = coordinator.start([package], userID: 0, loadPage: { _, _ in
            try await currentGate.load()
        }) { recorder.record($0) }
        await currentGate.waitUntilRequested()
        await oldGate.succeed([package.packageName: .init(displayName: "Old")])
        await old.value
        coordinator.cancel()
        XCTAssertTrue(current.isCancelled)
        await currentGate.succeed([package.packageName: .init(displayName: "New")])
        await current.value
        XCTAssertTrue(recorder.order.isEmpty)
    }

    func testCurrentUserChangeErrorIsPublishedButAReplacedFailureIsIgnored() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.app")
        let oldGate = DetailGate()
        let recorder = DetailEvents()
        let coordinator = ADBTVInstalledAppDetailsCoordinator()
        let old = coordinator.start([package], userID: 0, loadPage: { _, _ in
            try await oldGate.load()
        }) { recorder.record($0) }
        await oldGate.waitUntilRequested()
        let current = coordinator.start([package], userID: 10, loadPage: { _, _ in
            throw ADBTVInstalledAppError.activeUserChanged(expected: 10, actual: 11)
        }) { recorder.record($0) }
        await current.value
        await oldGate.fail(ADBTVInstalledAppError.activeUserChanged(expected: 0, actual: 10))
        await old.value
        XCTAssertEqual(recorder.order, ["failed"])
        XCTAssertEqual(recorder.lastError as? ADBTVInstalledAppError, .activeUserChanged(expected: 10, actual: 11))
    }

    func testDroppingTheCoordinatorCancelsItsOwnedTask() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.app")
        let gate = DetailGate()
        let recorder = DetailEvents()
        var coordinator: ADBTVInstalledAppDetailsCoordinator? = .init()
        let task = try XCTUnwrap(coordinator).start([package], userID: 0, loadPage: { _, _ in
            try await gate.load()
        }) { recorder.record($0) }
        await gate.waitUntilRequested()
        coordinator = nil
        XCTAssertTrue(task.isCancelled)
        await gate.succeed([:])
        await task.value
        XCTAssertTrue(recorder.order.isEmpty)
    }
}

@MainActor
private final class DetailEvents {
    var pageCounts: [Int] = []
    var packageNames: [[String]] = []
    var finished: [ADBTVInstalledAppDetailsLoadResult] = []
    var failureDescriptions: [String] = []
    var lastError: (any Error)?
    var order: [String] = []

    func record(_ event: ADBTVInstalledAppDetailsEvent) {
        switch event {
        case .page(let packages, let details):
            pageCounts.append(details.count)
            packageNames.append(packages.map(\.packageName))
            order.append("page")
        case .finished(let result):
            finished.append(result)
            order.append("finished")
        case .failed(let error):
            lastError = error
            failureDescriptions.append(String(describing: error))
            order.append("failed")
        }
    }
}

private actor DetailCalls {
    private(set) var userIDs: [Int] = []
    func record(_ packages: [ADBTVInstalledPackage], userID: Int) { userIDs.append(userID) }
}

private actor DetailGate {
    private var continuation: CheckedContinuation<[String: ADBTVInstalledAppDetails], Error>?
    private var requested: CheckedContinuation<Void, Never>?

    func load() async throws -> [String: ADBTVInstalledAppDetails] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitUntilRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func succeed(_ details: [String: ADBTVInstalledAppDetails]) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: details)
    }

    func fail(_ error: any Error) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(throwing: error)
    }
}
