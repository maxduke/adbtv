import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVListPresentationTests: XCTestCase {
    func testFileRowsUpdateWhenSearchIsEditedAndClearedWithoutLosingOriginalEntries() throws {
        let files = try [file("café.apk", bytes: 10), file("电影.mp4", bytes: 100), file("file2.apk", bytes: 20)]
        var listing = ADBTVFileBrowserListing(items: files)
        listing.query.searchText = "  CAFE  "
        XCTAssertEqual(listing.visibleItems.map(\.name), ["café.apk"])
        XCTAssertEqual(listing.items, files)
        listing.query.searchText = "missing"
        XCTAssertTrue(listing.visibleItems.isEmpty)
        XCTAssertEqual(listing.emptyState(status: .ready), .noMatches)
        listing.query.searchText = ""
        XCTAssertEqual(Set(listing.visibleItems.map(\.name)), Set(files.map(\.name)))
        XCTAssertNil(listing.emptyState(status: .ready))
    }

    func testDirectoryReplacementKeepsTheSelectedSearchAndSort() throws {
        var listing = ADBTVFileBrowserListing(
            items: try [file("old.apk", bytes: 1)],
            query: .init(searchText: ".apk", sortOrder: .largest)
        )
        listing.replaceItems(try [file("small.apk", bytes: 10), file("large.apk", bytes: 20), file("movie.mp4", bytes: 30)])
        XCTAssertEqual(listing.visibleItems.map(\.name), ["large.apk", "small.apk"])
        listing.query.sortOrder = .name
        XCTAssertEqual(listing.visibleItems.map(\.name), ["large.apk", "small.apk"])
        listing.query.sortOrder = .newest
        XCTAssertEqual(listing.visibleItems.map(\.name), ["small.apk", "large.apk"])
    }

    func testLocaleRefreshRetainsQueryAndProducesTheCurrentLocalesProjection() throws {
        let files = try [file("ä2.apk"), file("z10.apk"), file("z2.apk")]
        let query = ADBTVFileBrowserQuery(searchText: "apk")
        var listing = ADBTVFileBrowserListing(items: files, query: query, locale: Locale(identifier: "en_US"))
        let updatedLocale = Locale(identifier: "sv_SE")
        listing.updateLocale(updatedLocale)
        XCTAssertEqual(listing.locale, updatedLocale)
        XCTAssertEqual(listing.query, query)
        XCTAssertEqual(listing.visibleItems, query.apply(to: files, locale: updatedLocale))
    }

    func testCachedEmptyResultsDoNotReplaceLoadingOrFailureAndRecoverOnNewEntries() throws {
        var listing = ADBTVFileBrowserListing(query: .init(searchText: "keep"))
        XCTAssertEqual(listing.emptyState(status: .ready), .emptyFolder)
        let failure = ADBTVFileListStatus.failed(.init(userMessage: "offline", diagnosticDetail: .init(summary: "offline")))
        for status in [ADBTVFileListStatus.idle, .loading, failure] {
            XCTAssertNil(listing.emptyState(status: status))
        }
        listing.replaceItems(try [file("other.apk")])
        XCTAssertEqual(listing.emptyState(status: .ready), .noMatches)
        listing.replaceItems(try [file("keep.apk")])
        XCTAssertNil(listing.emptyState(status: .ready))
        XCTAssertEqual(listing.visibleItems.map(\.name), ["keep.apk"])
    }

    func testActivePackageIndexTracksSnapshotReplacementAndClear() throws {
        let first = try app("com.example.first", foreground: true)
        let second = try app("com.example.second", foreground: false)
        var state = ADBTVInstalledAppsViewState(mode: .active, activitySnapshot: .init(userID: 0, apps: [first], capturedAt: Date()))
        XCTAssertEqual(state.activeAppsByPackage, [first.package.packageName: first])
        state.activitySnapshot = .init(userID: 10, apps: [second], capturedAt: Date())
        XCTAssertEqual(state.activeAppsByPackage, [second.package.packageName: second])
        XCTAssertNil(state.activeAppsByPackage[first.package.packageName])
        state.activitySnapshot = nil
        XCTAssertTrue(state.activeAppsByPackage.isEmpty)
    }

    func testActiveIndexKeepsFirstDuplicateAndEmptyStateUsesTheAlreadyFilteredRows() throws {
        let first = try app("com.example.app", foreground: true)
        let duplicate = try app("com.example.app", foreground: false)
        var state = ADBTVInstalledAppsViewState(userID: 0, mode: .active,
            activitySnapshot: .init(userID: 0, apps: [first, duplicate], capturedAt: Date()), status: .ready(message: nil))
        XCTAssertEqual(state.activeAppsByPackage[first.package.packageName], first)
        XCTAssertNil(state.emptyState(filteredPackages: [first.package]))
        XCTAssertEqual(state.emptyState(filteredPackages: []), .noMatches)
        state.status = .loadingActivity
        XCTAssertNil(state.emptyState(filteredPackages: []))
        state.status = .ready(message: nil)
        state.activitySnapshot = .init(userID: 0, apps: [], capturedAt: Date())
        XCTAssertEqual(state.emptyState(filteredPackages: []), .noApps)
    }

    private func file(_ name: String, bytes: UInt32 = 0) throws -> ADBSharedStorageItem {
        ADBSharedStorageItem(path: try .root.appendingPathComponent(name), entry: .init(
            name: name, mode: .init(rawValue: 0o100644), byteCount: bytes,
            modificationTime: 100 - min(bytes, 100)
        ))
    }

    private func app(_ name: String, foreground: Bool) throws -> ADBTVActiveApp {
        ADBTVActiveApp(package: try .init(packageName: name), kind: .user,
            isForeground: foreground, memoryByteCount: 1024, processCount: 1)
    }
}
