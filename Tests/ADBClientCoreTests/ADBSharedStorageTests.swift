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

    func testUploadReplacesDestinationOnlyAfterTemporaryUploadCompletes() async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBSharedStorageTests-\(UUID().uuidString).txt")
        try Data([1, 2, 3]).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        var manager = ADBSharedStorageManager(session: RecordingSharedStorageSession())

        let destination = try await manager.upload(localURL, to: .root, replacingExisting: true)

        XCTAssertEqual(destination.rawValue, "/sdcard/\(localURL.lastPathComponent)")
        let temporaryPath = try XCTUnwrap(manager.session.pushPlans.first?.remotePath.rawValue)
        XCTAssertTrue(temporaryPath.hasPrefix("/sdcard/.adbtv-upload-"))
        XCTAssertEqual(manager.session.shellCommands.count, 1)
        XCTAssertTrue(manager.session.shellCommands[0].contains(
            "mv -f '\(temporaryPath)' '\(destination.rawValue)'"
        ))
    }

    func testFailedUploadRemovesTemporaryFileWithoutReplacingDestination() async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBSharedStorageTests-\(UUID().uuidString).txt")
        try Data([1, 2, 3]).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        var manager = ADBSharedStorageManager(
            session: RecordingSharedStorageSession(pushError: TestSharedStorageError.pushFailed)
        )

        do {
            _ = try await manager.upload(localURL, to: .root)
            XCTFail("Expected upload to fail.")
        } catch {
            XCTAssertEqual(error as? TestSharedStorageError, .pushFailed)
        }

        let temporaryPath = try XCTUnwrap(manager.session.pushPlans.first?.remotePath.rawValue)
        XCTAssertEqual(manager.session.shellCommands.count, 1)
        XCTAssertTrue(manager.session.shellCommands[0].contains("rm -f '\(temporaryPath)'"))
        XCTAssertFalse(manager.session.shellCommands[0].contains("mv -f"))
    }

    func testUploadCleanupFailurePreservesBothErrorsAndExactStagingPath() async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBSharedStorageTests-\(UUID().uuidString).txt")
        try Data([1]).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        var manager = ADBSharedStorageManager(session: RecordingSharedStorageSession(
            pushError: .pushFailed,
            shellError: .cleanupFailed
        ))

        do {
            _ = try await manager.upload(localURL, to: .root)
            XCTFail("Expected cleanup failure.")
        } catch let error as ADBSharedStorageUploadCleanupError {
            XCTAssertEqual(error.temporaryPath.remotePath, manager.session.pushPlans.first?.remotePath)
            XCTAssertTrue(error.underlyingError.contains("pushFailed"))
            XCTAssertTrue(error.cleanupError.contains("cleanupFailed"))
        }
    }

    func testUploadUsesProvidedCleanupInsteadOfFailedSession() async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBSharedStorageTests-\(UUID().uuidString).txt")
        try Data([1]).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let cleanup = SharedStorageCleanupObservation()
        var manager = ADBSharedStorageManager(session: RecordingSharedStorageSession(
            pushError: .pushFailed,
            shellError: .cleanupFailed
        ))

        do {
            _ = try await manager.upload(localURL, to: .root, cleanup: { path in
                await cleanup.record(path)
                return nil
            })
            XCTFail("Expected upload failure.")
        } catch {
            XCTAssertEqual(error as? TestSharedStorageError, .pushFailed)
        }
        let cleanedPath = await cleanup.path
        XCTAssertEqual(cleanedPath?.remotePath, manager.session.pushPlans.first?.remotePath)
        XCTAssertTrue(manager.session.shellCommands.isEmpty)
    }

#if os(macOS) || os(Linux)
    func testUploadCommitRejectsFileCreatedAfterDirectorySnapshot() throws {
        try withUploadFixture { source, target in
            try Data("original".utf8).write(to: target)

            XCTAssertNotEqual(try commit(source, to: target, replacing: false), 0)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testUploadCommitRejectsDirectoryEvenWhenReplacementWasConfirmed() throws {
        try withUploadFixture { source, target in
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

            XCTAssertNotEqual(try commit(source, to: target, replacing: true), 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testUploadCommitRejectsSymlinkWithoutChangingItsTarget() throws {
        try withUploadFixture { source, target in
            let original = target.deletingLastPathComponent().appendingPathComponent("original")
            try Data("original".utf8).write(to: original)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)

            XCTAssertNotEqual(try commit(source, to: target, replacing: true), 0)
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        }
    }

    func testUploadCommitCreatesNewFileAndAllowsConfirmedReplacement() throws {
        for replacing in [false, true] {
            try withUploadFixture { source, target in
                if replacing { try Data("original".utf8).write(to: target) }

                XCTAssertEqual(try commit(source, to: target, replacing: replacing), 0)
                XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "uploaded")
                XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            }
        }
    }

    private func withUploadFixture(_ work: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBSharedStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(".adbtv-upload-test")
        let target = directory.appendingPathComponent("O'Reilly file.txt")
        try Data("uploaded".utf8).write(to: source)
        try work(source, target)
    }

    private func commit(_ source: URL, to target: URL, replacing: Bool) throws -> Int32 {
        let command = ADBSharedStorageManager<RecordingSharedStorageSession>.uploadCommitCommand(
            temporary: try ADBRemotePath(source.path),
            destination: try ADBRemotePath(target.path),
            replacingExisting: replacing
        )
        let invocation = try ADBCheckedShellInvocation(command: ADBShellCommand(command))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", invocation.shellCommand.rawValue]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Int32(try invocation.result(from: ADBShellOutput(bytes: Array(bytes))).exitCode)
    }
#endif

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
    var pushPlans: [ADBSyncPushPlan] = []
    var pushError: TestSharedStorageError?
    var shellError: TestSharedStorageError?

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
        pushPlans.append(plan)
        if let pushError {
            throw pushError
        }
        return [.completed]
    }

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        shellCommands.append(command.rawValue)
        if let shellError { throw shellError }
        return ADBShellOutput(bytes: Array("\n__ADBTV_EXIT_STATUS__=0\n".utf8))
    }
}

private enum TestSharedStorageError: Error, Equatable {
    case pushFailed
    case cleanupFailed
}

private actor SharedStorageCleanupObservation {
    private(set) var path: ADBSharedStoragePath?

    func record(_ path: ADBSharedStoragePath) {
        self.path = path
    }
}
