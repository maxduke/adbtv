import Foundation
import XCTest
@testable import ADBClientCore

final class ADBPackageSessionInstallerTests: XCTestCase {
    func testInstallsEveryFileInOnePackageManagerSession() async throws {
        let files = try makeFiles([("base.apk", 4), ("split_config.en.apk", 3)])
        defer { files.forEach { try? FileManager.default.removeItem(at: $0.fileURL) } }
        var session = PackageSessionRecorder(
            outputs: [
                ADBServiceOutput(bytes: Array("Success: created install session [42]\n".utf8)),
                ADBServiceOutput(bytes: Array("Success\n".utf8)),
                ADBServiceOutput(bytes: Array("Success\n".utf8)),
                ADBServiceOutput(bytes: Array("Success\n".utf8))
            ]
        )

        let result = try await ADBPackageSessionInstaller().install(
            files: files,
            using: &session
        )

        XCTAssertEqual(result, .success)
        XCTAssertEqual(session.calls.map(\.service), [
            "exec:cmd package install-create -r -S 7",
            "exec:cmd package install-write -S 4 42 base.apk -",
            "exec:cmd package install-write -S 3 42 split_1.apk -",
            "exec:cmd package install-commit 42"
        ])
    }

    func testAbandonsSessionWhenWritingSplitFails() async throws {
        let files = try makeFiles([("base.apk", 4)])
        defer { files.forEach { try? FileManager.default.removeItem(at: $0.fileURL) } }
        var session = PackageSessionRecorder(
            outputs: [
                ADBServiceOutput(bytes: Array("Success: created install session [9]\n".utf8)),
                ADBServiceOutput(bytes: Array("Failure [INSTALL_FAILED_INVALID_APK]\n".utf8)),
                ADBServiceOutput(bytes: Array("Success\n".utf8))
            ]
        )

        do {
            _ = try await ADBPackageSessionInstaller().install(files: files, using: &session)
            XCTFail("Expected split write failure")
        } catch {
            XCTAssertTrue(error is ADBPackageSessionInstallError)
        }
        XCTAssertEqual(session.calls.map(\.service), [
            "exec:cmd package install-create -r -S 4",
            "exec:cmd package install-write -S 4 9 base.apk -",
            "exec:cmd package install-abandon 9"
        ])
    }

    func testRetainsSessionIDWhenAbandonFails() async throws {
        let files = try makeFiles([("base.apk", 4)])
        defer { files.forEach { try? FileManager.default.removeItem(at: $0.fileURL) } }
        var session = PackageSessionRecorder(
            outputs: [
                ADBServiceOutput(bytes: Array("Success: created install session [9]\n".utf8)),
                ADBServiceOutput(bytes: Array("Failure [write]\n".utf8)),
                ADBServiceOutput(bytes: Array("Failure [abandon]\n".utf8))
            ]
        )

        do {
            _ = try await ADBPackageSessionInstaller().install(files: files, using: &session)
            XCTFail("Expected split write failure")
        } catch let error as ADBPackageSessionInstallError {
            guard case let .operationFailed(sessionID, _, abandonError) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertEqual(sessionID, 9)
            XCTAssertNotNil(abandonError)
        }
    }

    func testParsesCreatedSessionID() throws {
        XCTAssertEqual(
            try ADBPackageSessionInstaller.parseSessionID(
                "Success: created install session [123]\n"
            ),
            123
        )
        XCTAssertThrowsError(try ADBPackageSessionInstaller.parseSessionID("Failure [broken]"))
    }

    private func makeFiles(_ specifications: [(String, Int)]) throws -> [ADBPackageSessionFile] {
        try specifications.map { fileName, byteCount in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 1, count: byteCount).write(to: url)
            return try ADBPackageSessionFile(
                fileURL: url,
                fileName: fileName,
                byteCount: Int64(byteCount)
            )
        }
    }
}

private struct PackageSessionRecorder: ADBPackageSessionRunning {
    struct Call: Equatable {
        let service: String
        let fileURL: URL?
    }

    var outputs: [ADBServiceOutput]
    private(set) var calls: [Call] = []

    mutating func runService(
        _ service: String,
        maximumOutputByteCount: Int
    ) async throws -> ADBServiceOutput {
        calls.append(Call(service: service, fileURL: nil))
        return outputs.removeFirst()
    }

    mutating func runService(
        _ service: String,
        inputFrom fileURL: URL,
        inputByteCount: Int64,
        maximumOutputByteCount: Int,
        progressHandler: @escaping @Sendable (Int64) async -> Void
    ) async throws -> ADBServiceOutput {
        calls.append(Call(service: service, fileURL: fileURL))
        await progressHandler(inputByteCount)
        return outputs.removeFirst()
    }
}
