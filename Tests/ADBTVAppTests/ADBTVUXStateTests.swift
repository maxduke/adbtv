import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVUXStateTests: XCTestCase {
    private let failure = ADBTVInstalledAppsStatus.failed(
        userMessage: "Could not load apps.",
        diagnosticDetail: DiagnosticDetail(summary: "Timed out.")
    )

    func testUnloadedAndFailedListsNeverClaimToBeEmpty() {
        var state = ADBTVInstalledAppsViewState()
        for status in [ADBTVInstalledAppsStatus.idle, .loading, failure, .ready(message: "Cancelled.")] {
            state.status = status
            XCTAssertNil(state.emptyState(matching: ""))
            XCTAssertNil(state.emptyState(matching: "Netflix"))
        }
    }

    func testSuccessfulEmptySnapshotIsDistinctFromUnmatchedSearch() throws {
        var state = ADBTVInstalledAppsViewState(userID: 10, status: .ready(message: nil))
        XCTAssertEqual(state.emptyState(matching: ""), .noApps)
        XCTAssertEqual(state.emptyState(matching: "Netflix"), .noApps)

        let package = try ADBTVInstalledPackage(packageName: "com.netflix.ninja")
        state.packages = [package]
        state.details = [package.packageName: ADBTVInstalledAppDetails(displayName: "Netflix")]
        XCTAssertNil(state.emptyState(matching: "  NETFLIX  "))
        XCTAssertEqual(state.filteredPackages(matching: "  NETFLIX  "), [package])
        XCTAssertEqual(state.filteredPackages(matching: "com.netflix"), [package])
        XCTAssertEqual(state.filteredPackages(matching: " \n "), [package])
        XCTAssertEqual(state.emptyState(matching: "missing"), .noMatches)

        state.status = .loading
        XCTAssertNil(state.emptyState(matching: "missing"))
        state.status = failure
        XCTAssertNil(state.emptyState(matching: "missing"))
        XCTAssertEqual(state.filteredPackages(matching: "Netflix"), [package])
    }

    func testFailedRefreshPreservesListIdentityAndSystemState() throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.tv")
        let snapshot = ADBTVSystemAppSnapshot(
            userID: 10, packages: [package], disabledPackageNames: [package.packageName],
            protectionReasons: [:]
        )
        let details = [package.packageName: ADBTVInstalledAppDetails(displayName: "TV App")]
        var state = ADBTVInstalledAppsViewState(
            userID: 10, mode: .system, packages: [package], details: details,
            systemSnapshot: snapshot, status: .ready(message: nil)
        )
        state.prepareListRefresh(mode: .system)
        state.status = .loading
        XCTAssertEqual(state.filteredPackages(matching: "TV App"), [package])
        state.status = failure
        XCTAssertEqual(state.displayedPackages, [package])
        XCTAssertEqual(state.details, details)
        XCTAssertEqual(state.systemSnapshot, snapshot)
        XCTAssertEqual(state.userID, 10)
        XCTAssertNil(state.emptyState(matching: ""))

        state.recordListSnapshot([], userID: 11)
        XCTAssertEqual(state.userID, 11)
        XCTAssertTrue(state.details.isEmpty)
        XCTAssertNil(state.systemSnapshot)
        XCTAssertEqual(state.emptyState(matching: "TV App"), .noApps)
    }

    func testSwitchingAppScopeDoesNotReusePreviousScopesEmptyStateOrRows() throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.tv")
        var state = ADBTVInstalledAppsViewState(
            userID: 10, packages: [package],
            details: [package.packageName: ADBTVInstalledAppDetails(displayName: "TV App")],
            status: .ready(message: nil)
        )
        state.prepareListRefresh(mode: .system)
        XCTAssertTrue(state.packages.isEmpty)
        XCTAssertTrue(state.details.isEmpty)
        XCTAssertNil(state.userID)
        XCTAssertNil(state.emptyState(matching: ""))
    }

    func testActiveListUsesItsOwnSnapshotForSearchAndEmptyState() throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.tv")
        var state = ADBTVInstalledAppsViewState(
            userID: 10, mode: .active, packages: [package], status: .ready(message: nil)
        )
        XCTAssertNil(state.emptyState(matching: ""))
        state.activitySnapshot = ADBTVAppActivitySnapshot(userID: 0, apps: [], capturedAt: Date())
        XCTAssertEqual(state.emptyState(matching: ""), .noApps)
        XCTAssertTrue(state.filteredPackages(matching: "com.example").isEmpty)
        state.prepareActivityRefresh()
        state.status = .loadingActivity
        XCTAssertNil(state.emptyState(matching: ""))
        state.status = failure
        XCTAssertNil(state.emptyState(matching: ""))
        XCTAssertEqual(state.userID, 0)
    }

    func testRemoteRecoveryAndTextProgressAreProminentWithoutMovingRoutineKeyFeedback() {
        let detail = DiagnosticDetail(summary: "Timed out.")
        let priority: [ADBTVRemoteStatus] = [
            .connecting, .reconnecting, .catchingUp, .sendingText,
            .connectionFailed(userMessage: "Offline", diagnosticDetail: detail),
            .failed(action: .home, userMessage: "Failed", diagnosticDetail: detail),
            .failedText(userMessage: "Failed", diagnosticDetail: detail)
        ]
        for status in priority { XCTAssertTrue(status.showsPriorityFeedback) }
        for status in [ADBTVRemoteStatus.idle, .sending(.home), .sent(.home), .sentText] {
            XCTAssertFalse(status.showsPriorityFeedback)
        }
    }
}
