import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVQuickLaunchIconCacheTests: XCTestCase {
    func testNewCacheInstanceRestoresIconsOnlyForTheSavedTVAndUser() throws {
        let cache = makeCache()
        let package = try ADBTVInstalledPackage(packageName: "com.example.player")
        let icon = try fixtureIcon()
        let tv = UUID()
        cache.save([package.packageName: icon], packages: [package], deviceID: tv, userID: 10)
        let reopened = ADBTVQuickLaunchIconCache(directory: cache.directory)
        XCTAssertEqual(reopened.load([package], deviceID: tv, userID: 10)[package.packageName], icon)
        XCTAssertTrue(reopened.load([package], deviceID: tv, userID: 0).isEmpty)
        XCTAssertTrue(reopened.load([package], deviceID: UUID(), userID: 10).isEmpty)
    }

    func testCorruptAndOversizedCacheFilesAreDiscarded() throws {
        let cache = makeCache()
        let package = try ADBTVInstalledPackage(packageName: "com.example.player")
        let tv = UUID()
        let icon = try fixtureIcon()
        for data in [Data("broken".utf8), Data(icon.pngData.prefix(24)),
                     Data(repeating: 0, count: ADBTVInstalledAppIcon.maximumPNGByteCount + 1)] {
            cache.save([package.packageName: icon], packages: [package], deviceID: tv, userID: 0)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil).first)
            try data.write(to: file)
            XCTAssertTrue(cache.load([package], deviceID: tv, userID: 0).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testEvictsTheLeastRecentlyUsedEntryAndIgnoresUnrequestedIcons() throws {
        let cache = makeCache(limit: 2)
        let packages = try (0..<3).map { try ADBTVInstalledPackage(packageName: "com.example.app\($0)") }
        let icon = try fixtureIcon()
        let tv = UUID()
        cache.save(Dictionary(uniqueKeysWithValues: packages.map { ($0.packageName, icon) }),
                   packages: Array(packages.prefix(2)), deviceID: tv, userID: 0)
        let files = try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        }
        _ = cache.load([packages[0]], deviceID: tv, userID: 0)
        cache.save([packages[2].packageName: icon], packages: [packages[2]], deviceID: tv, userID: 0)
        let restored = cache.load(packages, deviceID: tv, userID: 0)
        XCTAssertEqual(Set(restored.keys), [packages[0].packageName, packages[2].packageName])
    }

    func testRemovingOneTVPreservesOtherTVsAndOtherFiles() throws {
        let cache = makeCache()
        let package = try ADBTVInstalledPackage(packageName: "com.example.player")
        let icon = try fixtureIcon()
        let first = UUID(), second = UUID()
        for tv in [first, second] {
            cache.save([package.packageName: icon], packages: [package], deviceID: tv, userID: 0)
        }
        let unrelated = cache.directory.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        cache.removeDevice(first)
        XCTAssertTrue(cache.load([package], deviceID: first, userID: 0).isEmpty)
        XCTAssertEqual(cache.load([package], deviceID: second, userID: 0)[package.packageName], icon)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCacheFailureDoesNotThrowOrChangeTheProvidedIcon() throws {
        let cache = makeCache()
        try Data("file instead of directory".utf8).write(to: cache.directory)
        let package = try ADBTVInstalledPackage(packageName: "com.example.player")
        let icon = try fixtureIcon()
        cache.save([package.packageName: icon], packages: [package], deviceID: UUID(), userID: 0)
        XCTAssertTrue(cache.load([package], deviceID: UUID(), userID: 0).isEmpty)
        XCTAssertGreaterThan(icon.pngData.count, 24)
    }

    private func makeCache(limit: Int = 128) -> ADBTVQuickLaunchIconCache {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return .init(directory: url, maximumEntryCount: limit)
    }

    private func fixtureIcon() throws -> ADBTVInstalledAppIcon {
        try ADBTVInstalledAppIcon(pngData: XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAFklEQVR4nGNQLrjznxLMMGrAqAFADAAEGl3wf2IiSgAAAABJRU5ErkJggg==")))
    }
}
