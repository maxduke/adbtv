import ADBClientCore
import XCTest
@testable import ADBTVApp

final class ADBTVFileBrowserQueryTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")

    func testSearchTrimsAndMatchesOnlyNamesWithoutChangingIdentifiers() throws {
        let items = try [item("café.APK"), item("ＡＰＫ-notes.txt"), item("电影.apk"), item("Movies", directory: true)]
        let filtered = ADBTVFileBrowserQuery(searchText: "  apk\n").apply(to: items, locale: locale)
        XCTAssertEqual(Set(filtered.map(\.name)), ["café.APK", "ＡＰＫ-notes.txt", "电影.apk"])
        XCTAssertEqual(filtered.first { $0.name == "café.APK" }?.id, items[0].id)
        XCTAssertEqual(ADBTVFileBrowserQuery(searchText: "CAFE").apply(to: items, locale: locale).map(\.name), ["café.APK"])
        XCTAssertTrue(ADBTVFileBrowserQuery(searchText: "sdcard").apply(to: items).isEmpty)
        XCTAssertEqual(ADBTVFileBrowserQuery(searchText: "  \n").apply(to: items).count, items.count)
    }

    func testNaturalNameOrderKeepsFoldersBeforeFilesAndBreaksEquivalentNamesDeterministically() throws {
        let items = try [item("file10.apk"), item("folder10", directory: true), item("file2.apk"),
                         item("folder2", directory: true), item("FILE2.apk")]
        let expected = ["folder2", "folder10", "FILE2.apk", "file2.apk", "file10.apk"]
        XCTAssertEqual(ADBTVFileBrowserQuery().apply(to: items, locale: locale).map(\.name), expected)
        XCTAssertEqual(ADBTVFileBrowserQuery().apply(to: Array(items.reversed()), locale: locale).map(\.name), expected)
    }

    func testNewestSortsEachGroupByDateThenNaturalName() throws {
        let items = try [item("old-folder", directory: true, modified: 1), item("new.apk", modified: 3),
                         item("new-folder", directory: true, modified: 2), item("old.apk", modified: 1),
                         item("tie10.apk", modified: 2), item("tie2.apk", modified: 2)]
        XCTAssertEqual(
            ADBTVFileBrowserQuery(sortOrder: .newest).apply(to: items, locale: locale).map(\.name),
            ["new-folder", "old-folder", "new.apk", "tie2.apk", "tie10.apk", "old.apk"]
        )
    }

    func testLargestKeepsFoldersAlphabeticalAndUsesFileSizeThenName() throws {
        let items = try [item("folderB", directory: true, bytes: 999), item("small.apk", bytes: 1),
                         item("folderA", directory: true, bytes: 0), item("large.apk", bytes: 100),
                         item("tie10.apk", bytes: 50), item("tie2.apk", bytes: 50)]
        let query = ADBTVFileBrowserQuery(searchText: "", sortOrder: .largest)
        XCTAssertEqual(query.apply(to: items, locale: locale).map(\.name),
                       ["folderA", "folderB", "large.apk", "tie2.apk", "tie10.apk", "small.apk"])
        XCTAssertEqual(ADBTVFileBrowserQuery(searchText: "tie", sortOrder: .largest)
            .apply(to: items, locale: locale).map(\.name), ["tie2.apk", "tie10.apk"])
    }

    func testEmptyFolderAndNoMatchesAreDistinctAndNeverReplaceLoadingOrFailure() throws {
        let items = try [item("keep.apk")]
        let query = ADBTVFileBrowserQuery(searchText: "missing")
        XCTAssertEqual(query.emptyState(items: [], status: .ready), .emptyFolder)
        XCTAssertEqual(query.emptyState(items: items, status: .ready), .noMatches)
        XCTAssertNil(ADBTVFileBrowserQuery().emptyState(items: items, status: .ready))
        let failure = ADBTVFileListStatus.failed(.init(userMessage: "offline", diagnosticDetail: .init(summary: "offline")))
        for status in [ADBTVFileListStatus.idle, .loading, failure] {
            XCTAssertNil(query.emptyState(items: [], status: status))
            XCTAssertNil(query.emptyState(items: items, status: status))
        }
    }

    private func item(_ name: String, directory: Bool = false,
                      bytes: UInt32 = 0, modified: UInt32 = 0) throws -> ADBSharedStorageItem {
        return ADBSharedStorageItem(
            path: try .root.appendingPathComponent(name),
            entry: ADBSyncDirectoryEntry(name: name,
                mode: ADBSyncFileMode(rawValue: directory ? 0o040755 : 0o100644),
                byteCount: bytes, modificationTime: modified)
        )
    }
}
