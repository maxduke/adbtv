import Foundation
import XCTest
@testable import ADBClientCore

final class ADBSharedStorageTests: XCTestCase {
    func testPathStaysInsideSharedStorage() throws {
        let download = try ADBSharedStoragePath.root.appendingPathComponent("Download")

        XCTAssertEqual(download.rawValue, "/sdcard/Download")
        XCTAssertEqual(download.parent, .root)
        XCTAssertTrue(download.isDescendant(of: .root))
        XCTAssertThrowsError(try ADBSharedStoragePath(ADBRemotePath("/data/local/tmp"))) { error in
            XCTAssertEqual(error as? ADBSharedStoragePathError, .outsideSharedStorage)
        }
    }

    func testContentsSortsFoldersBeforeFiles() async throws {
        var manager = ADBSharedStorageManager(session: RecordingSharedStorageSession(entries: [
            ADBSyncDirectoryEntry(
                name: "zeta.txt",
                mode: ADBSyncFileMode(rawValue: 0o100644),
                byteCount: 2,
                modificationTime: 0
            ),
            ADBSyncDirectoryEntry(
                name: "Movies",
                mode: ADBSyncFileMode(rawValue: 0o040755),
                byteCount: 0,
                modificationTime: 0
            ),
            ADBSyncDirectoryEntry(
                name: "alpha.txt",
                mode: ADBSyncFileMode(rawValue: 0o100644),
                byteCount: 1,
                modificationTime: 0
            )
        ]))

        let items = try await manager.contents(of: .root)

        XCTAssertEqual(items.map(\.name), ["Movies", "alpha.txt", "zeta.txt"])
        XCTAssertEqual(items.map(\.path.rawValue), [
            "/sdcard/Movies",
            "/sdcard/alpha.txt",
            "/sdcard/zeta.txt"
        ])
    }

    func testRenameUsesEscapedPathsAndDoesNotOverwrite() async throws {
        let item = try sharedItem(name: "O'Reilly.txt", kind: 0o100644)
        var manager = ADBSharedStorageManager(session: RecordingSharedStorageSession())

        let destination = try await manager.rename(item, to: "New Name.txt")

        XCTAssertEqual(destination.rawValue, "/sdcard/New Name.txt")
        XCTAssertEqual(manager.session.shellCommands.count, 1)
        XCTAssertTrue(manager.session.shellCommands[0].contains("[ -e '/sdcard/New Name.txt' ]"))
        XCTAssertTrue(manager.session.shellCommands[0].contains("mv '/sdcard/O'\\''Reilly.txt' '/sdcard/New Name.txt'"))
    }

    func testMoveRejectsDirectoryInsideItself() async throws {
        let item = try sharedItem(name: "Movies", kind: 0o040755)
        let child = try item.path.appendingPathComponent("Archive")
        var manager = ADBSharedStorageManager(session: RecordingSharedStorageSession())

        do {
            _ = try await manager.move(item, to: child)
            XCTFail("Expected move into the source directory to fail.")
        } catch let error as ADBSharedStorageError {
            XCTAssertEqual(error, .destinationInsideSource)
        }
        XCTAssertEqual(manager.session.shellCommands, [])
    }

    private func sharedItem(name: String, kind: UInt32) throws -> ADBSharedStorageItem {
        ADBSharedStorageItem(
            path: try ADBSharedStoragePath.root.appendingPathComponent(name),
            entry: ADBSyncDirectoryEntry(
                name: name,
                mode: ADBSyncFileMode(rawValue: kind),
                byteCount: 0,
                modificationTime: 0
            )
        )
    }
}

private struct RecordingSharedStorageSession: ADBSharedStorageSession {
    var entries: [ADBSyncDirectoryEntry] = []
    var shellCommands: [String] = []

    mutating func listDirectory(_ path: ADBRemotePath) async throws -> [ADBSyncDirectoryEntry] {
        entries
    }

    mutating func pullFile(
        _ remotePath: ADBRemotePath,
        to localURL: URL,
        expectedByteCount: Int64?,
        eventHandler: @escaping ADBSyncPullEventHandler
    ) async throws -> Int64 {
        0
    }

    mutating func pushFile(
        from localURL: URL,
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler
    ) async throws -> [ADBSyncPushEvent] {
        [.completed]
    }

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        shellCommands.append(command.rawValue)
        return ADBShellOutput(bytes: Array("\n__ADBTV_EXIT_STATUS__=0\n".utf8))
    }
}
