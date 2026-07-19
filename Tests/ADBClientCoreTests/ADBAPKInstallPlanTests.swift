import Foundation
import XCTest
@testable import ADBClientCore

final class ADBAPKInstallPlanTests: XCTestCase {
    private let stagingIdentifier = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

    func testSingleAPKPlanBuildsRemotePathAndCommands() throws {
        let expectedPath = "/data/local/tmp/adbtv/01234567-89ab-cdef-0123-456789abcdef.apk"
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "Example App.apk",
            byteCount: 42,
            stagingIdentifier: stagingIdentifier
        )

        XCTAssertEqual(plan.package, try ADBInstallPackage(fileName: "Example App.apk", byteCount: 42))
        XCTAssertEqual(plan.remoteAPKPath.rawValue, expectedPath)
        XCTAssertEqual(plan.phases, [
            .validatePackage,
            .prepareRemoteDirectory,
            .transferPackage,
            .installPackage,
            .cleanup
        ])
        XCTAssertEqual(
            try plan.prepareRemoteDirectoryShellCommand().rawValue,
            "mkdir -p '/data/local/tmp/adbtv' && rm -f '\(expectedPath)' && test ! -e '\(expectedPath)'"
        )
        XCTAssertEqual(
            try plan.installShellCommand().rawValue,
            "pm install -r '\(expectedPath)'"
        )
        XCTAssertEqual(
            try plan.cleanupShellCommand().rawValue,
            "rm -f '\(expectedPath)' && test ! -e '\(expectedPath)'"
        )
    }

    func testSingleAPKPlanUsesUniqueStagingPaths() throws {
        let first = try ADBAPKInstallPlan.singleAPK(fileName: "app.apk")
        let second = try ADBAPKInstallPlan.singleAPK(fileName: "app.apk")

        XCTAssertNotEqual(first.remoteAPKPath, second.remoteAPKPath)
        XCTAssertTrue(first.remoteAPKPath.rawValue.hasPrefix("/data/local/tmp/adbtv/"))
        XCTAssertTrue(first.remoteAPKPath.rawValue.hasSuffix(".apk"))
        XCTAssertEqual(first.package.fileName, "app.apk")
    }

    func testInstallCommandCanOmitReplaceOption() throws {
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            stagingIdentifier: stagingIdentifier,
            options: ADBAPKInstallOptions(replaceExisting: false)
        )

        XCTAssertEqual(
            try plan.installShellCommand().rawValue,
            "pm install '/data/local/tmp/adbtv/01234567-89ab-cdef-0123-456789abcdef.apk'"
        )
    }

    func testInstallPackagePreservesUppercaseAPKExtension() throws {
        let package = try ADBInstallPackage(fileName: "TV.APP.APK")

        XCTAssertEqual(package.fileName, "TV.APP.APK")
    }

    func testRemotePathShellEscapesSingleQuotes() throws {
        let path = try ADBRemotePath("/data/local/tmp/adbtv/O'Reilly.apk")

        XCTAssertEqual(path.shellEscaped, "'/data/local/tmp/adbtv/O'\\''Reilly.apk'")
        XCTAssertEqual(path.parentDirectory.rawValue, "/data/local/tmp/adbtv")
    }

    func testInstallPackageRejectsUnsupportedInputs() {
        XCTAssertThrowsError(try ADBInstallPackage(fileName: "app.apks")) { error in
            XCTAssertEqual(error as? ADBInstallPackageError, .unsupportedFileExtension)
        }
        XCTAssertThrowsError(try ADBInstallPackage(fileName: "../app.apk")) { error in
            XCTAssertEqual(error as? ADBInstallPackageError, .pathSeparatorInFileName)
        }
        XCTAssertThrowsError(try ADBInstallPackage(fileName: "bad\u{0}.apk")) { error in
            XCTAssertEqual(error as? ADBInstallPackageError, .containsNullByte)
        }
        XCTAssertThrowsError(try ADBInstallPackage(fileName: "app.apk", byteCount: -1)) { error in
            XCTAssertEqual(error as? ADBInstallPackageError, .negativeByteCount)
        }
    }

    func testRemotePathRejectsUnsafeInputs() {
        XCTAssertThrowsError(try ADBRemotePath("relative/path.apk")) { error in
            XCTAssertEqual(error as? ADBRemotePathError, .notAbsolute)
        }
        XCTAssertThrowsError(try ADBRemotePath("/tmp/bad\npath.apk")) { error in
            XCTAssertEqual(error as? ADBRemotePathError, .containsNewline)
        }
        XCTAssertThrowsError(try ADBRemotePath("/tmp/bad\u{0}path.apk")) { error in
            XCTAssertEqual(error as? ADBRemotePathError, .containsNullByte)
        }
        XCTAssertThrowsError(try ADBRemotePath("/tmp").appendingPathComponent("nested/app.apk")) { error in
            XCTAssertEqual(error as? ADBRemotePathError, .pathSeparatorInComponent)
        }
        XCTAssertThrowsError(try ADBRemotePath.sharedStorageDirectory.appendingPathComponent("..")) { error in
            XCTAssertEqual(error as? ADBRemotePathError, .relativePathComponent)
        }
    }

    func testInstallResultParsesSuccessFailureAndErrors() {
        XCTAssertEqual(ADBAPKInstallResult.parse(output: "Success\n"), .success)
        XCTAssertEqual(
            ADBAPKInstallResult.parse(output: "Failure [INSTALL_FAILED_ALREADY_EXISTS]\n"),
            .failure(message: "INSTALL_FAILED_ALREADY_EXISTS")
        )
        XCTAssertEqual(
            ADBAPKInstallResult.parse(output: "Error: Failed to parse APK file: /data/local/tmp/app.apk\n"),
            .failure(message: "Error: Failed to parse APK file: /data/local/tmp/app.apk")
        )
        XCTAssertEqual(
            ADBAPKInstallResult.parse(output: ""),
            .failure(message: "Unknown install failure")
        )
    }
}
