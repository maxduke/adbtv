import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

@MainActor
final class ADBTVQuickLaunchIconsTests: XCTestCase {
    func testColdLaunchRestoresCachedIconBeforeItsOwnMetadataRequestFinishes() async throws {
        let cache = makeCache()
        let package = try package()
        let icon = try icon()
        let tv = UUID()
        let first = ADBTVQuickLaunchIcons(cache: cache)
        try await first.load(packages: [package], deviceID: tv, userID: 10) { packages, userID in
            XCTAssertEqual(packages, [package])
            XCTAssertEqual(userID, 10)
            return [package.packageName: .init(icon: icon)]
        }
        let reopened = ADBTVQuickLaunchIcons(cache: .init(directory: cache.directory))
        let gate = IconGate()
        let task = Task {
            try await reopened.load(packages: [package], deviceID: tv, userID: 10) { _, _ in try await gate.load() }
        }
        await gate.waitUntilRequested()
        XCTAssertEqual(reopened.icon(for: package.packageName, deviceID: tv, userID: 10), icon)
        XCTAssertNil(reopened.icon(for: package.packageName, deviceID: tv, userID: 0))
        XCTAssertNil(reopened.icon(for: package.packageName, deviceID: UUID(), userID: 10))
        await gate.finish(.success([:]))
        try await task.value
    }

    func testCancelledLateResponseCannotPublishOrPopulateTheCache() async throws {
        let cache = makeCache()
        let model = ADBTVQuickLaunchIcons(cache: cache)
        let package = try package(), icon = try icon(), tv = UUID()
        let gate = IconGate()
        let task = Task {
            try await model.load(packages: [package], deviceID: tv, userID: 0) { _, _ in try await gate.load() }
        }
        await gate.waitUntilRequested()
        task.cancel()
        model.cancel()
        await gate.finish(.success([package.packageName: .init(icon: icon)]))
        try await task.value
        XCTAssertTrue(model.icons.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(cache.load([package], deviceID: tv, userID: 0).isEmpty)
    }

    func testReplacementRejectsOldUserAndDeviceResponseEvenWithoutTaskCancellation() async throws {
        let cache = makeCache(), oldTV = UUID(), newTV = UUID()
        let model = ADBTVQuickLaunchIcons(cache: cache)
        let package = try package(), icon = try icon(), gate = IconGate()
        let old = Task {
            try await model.load(packages: [package], deviceID: oldTV, userID: 0) { _, _ in try await gate.load() }
        }
        await gate.waitUntilRequested()
        try await model.load(packages: [package], deviceID: newTV, userID: 10) { _, _ in [:] }
        await gate.finish(.success([package.packageName: .init(icon: icon)]))
        try await old.value
        XCTAssertTrue(model.icons.isEmpty)
        XCTAssertNil(model.failure)
        XCTAssertTrue(cache.load([package], deviceID: oldTV, userID: 0).isEmpty)
    }

    func testTransientFailureRetainsCachedIconsAndDoesNotPreventLaunch() async throws {
        let cache = makeCache(), tv = UUID()
        let package = try package(), icon = try icon()
        cache.save([package.packageName: icon], packages: [package], deviceID: tv, userID: 0)
        let model = ADBTVQuickLaunchIcons(cache: cache)
        try await model.load(packages: [package], deviceID: tv, userID: 0) { _, _ in
            throw ADBTVInstalledAppError.detailsHelperUnavailable
        }
        XCTAssertEqual(model.icon(for: package.packageName, deviceID: tv, userID: 0), icon)
        XCTAssertNotNil(model.failure)
        XCTAssertFalse(model.isLoading)
    }

    func testUserChangeClearsIconsAndPropagatesToInvalidatePins() async throws {
        let cache = makeCache(), tv = UUID()
        let package = try package(), icon = try icon()
        cache.save([package.packageName: icon], packages: [package], deviceID: tv, userID: 0)
        let model = ADBTVQuickLaunchIcons(cache: cache)
        do {
            try await model.load(packages: [package], deviceID: tv, userID: 0) { _, _ in
                throw ADBTVInstalledAppError.activeUserChanged(expected: 0, actual: 10)
            }
            XCTFail("Expected the changed TV user to invalidate pins.")
        } catch {
            XCTAssertEqual(error as? ADBTVInstalledAppError, .activeUserChanged(expected: 0, actual: 10))
        }
        XCTAssertTrue(model.icons.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testOnlyRequestedIconsArePublishedAndCacheWriteFailureIsNonfatal() async throws {
        let cache = makeCache(), tv = UUID()
        try Data("unwritable cache directory".utf8).write(to: cache.directory)
        let model = ADBTVQuickLaunchIcons(cache: cache)
        let package = try package(), icon = try icon()
        try await model.load(packages: [package], deviceID: tv, userID: 0) { _, _ in
            [package.packageName: .init(icon: icon), "com.example.unrequested": .init(icon: icon)]
        }
        XCTAssertEqual(Set(model.icons.keys), [package.packageName])
        XCTAssertNil(model.failure)
    }

    private func makeCache() -> ADBTVQuickLaunchIconCache {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return .init(directory: url)
    }
    private func package() throws -> ADBTVInstalledPackage {
        try ADBTVInstalledPackage(packageName: "com.example.player")
    }
    private func icon() throws -> ADBTVInstalledAppIcon {
        try ADBTVInstalledAppIcon(pngData: XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAFklEQVR4nGNQLrjznxLMMGrAqAFADAAEGl3wf2IiSgAAAABJRU5ErkJggg==")))
    }
}

private actor IconGate {
    private var continuation: CheckedContinuation<[String: ADBTVInstalledAppDetails], Error>?
    private var requested: CheckedContinuation<Void, Never>?
    func load() async throws -> [String: ADBTVInstalledAppDetails] {
        try await withCheckedThrowingContinuation {
            continuation = $0
            requested?.resume()
            requested = nil
        }
    }
    func waitUntilRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { requested = $0 }
    }
    func finish(_ result: Result<[String: ADBTVInstalledAppDetails], Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
