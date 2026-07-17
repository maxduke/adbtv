import XCTest
@testable import ADBClientCore

final class ADBTVInstalledAppManagerTests: XCTestCase {
    func testListParsesSortsAndDeduplicatesThirdPartyPackages() async throws {
        var session = InstalledAppSession(outputs: [
            checkedOutput("package:com.netflix.ninja\npackage:com.example.player\npackage:com.netflix.ninja\n")
        ])

        let packages = try await ADBTVInstalledAppManager().list(using: &session)

        XCTAssertEqual(packages.map(\.packageName), ["com.example.player", "com.netflix.ninja"])
        XCTAssertTrue(session.commands[0].hasPrefix("pm list packages -3; "))
    }

    func testListRejectsUnexpectedOutput() async {
        var session = InstalledAppSession(outputs: [checkedOutput("warning: unavailable\n")])

        do {
            _ = try await ADBTVInstalledAppManager().list(using: &session)
            XCTFail("Expected package parsing to fail.")
        } catch let error as ADBTVInstalledAppError {
            XCTAssertEqual(error, .invalidPackageListLine("warning: unavailable"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPackageNameRejectsShellMetacharacters() {
        XCTAssertThrowsError(try ADBTVInstalledPackage(packageName: "com.example;reboot")) {
            XCTAssertEqual(
                $0 as? ADBTVInstalledAppError,
                .invalidPackageName("com.example;reboot")
            )
        }
    }

    func testLaunchTriesLeanbackBeforeStandardLauncher() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.player")
        var session = InstalledAppSession(outputs: [checkedOutput("")])

        try await ADBTVInstalledAppManager().launch(package, using: &session)

        XCTAssertTrue(session.commands[0].contains("android.intent.category.LEANBACK_LAUNCHER"))
        XCTAssertTrue(session.commands[0].contains("|| monkey"))
        XCTAssertTrue(session.commands[0].contains("android.intent.category.LAUNCHER"))
        XCTAssertTrue(session.commands[0].contains("'com.example.player'"))
    }

    func testUninstallRequiresSuccessOutput() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.player")
        var session = InstalledAppSession(outputs: [checkedOutput("Failure [blocked]\n")])

        do {
            try await ADBTVInstalledAppManager().uninstall(package, using: &session)
            XCTFail("Expected uninstall output validation to fail.")
        } catch let error as ADBTVInstalledAppError {
            XCTAssertEqual(error, .unexpectedUninstallOutput("Failure [blocked]"))
        }
        XCTAssertTrue(session.commands[0].hasPrefix("pm uninstall 'com.example.player'; "))
    }

    func testIconsLoadValidPNGAndIgnoreInvalidItems() async throws {
        let validPNG = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let response = """
        [
          {"package":"com.example.player","png":"\(validPNG.base64EncodedString())"},
          {"package":"com.example.invalid","png":"not-base64"},
          {"package":"com.unrequested.app","png":"\(validPNG.base64EncodedString())"}
        ]
        """
        var session = InstalledAppSession(outputs: [checkedOutput(response)])
        let packages = [
            try ADBTVInstalledPackage(packageName: "com.example.player"),
            try ADBTVInstalledPackage(packageName: "com.example.invalid")
        ]

        let icons = await ADBTVInstalledAppManager().icons(for: packages, using: &session)

        XCTAssertEqual(icons["com.example.player"]?.pngData, validPNG)
        XCTAssertNil(icons["com.example.invalid"])
        XCTAssertNil(icons["com.unrequested.app"])
        XCTAssertTrue(session.commands[0].contains("content://com.maxduke.adbtv.input.icons/icons"))
        XCTAssertTrue(session.commands[0].contains("head -c 1048576"))
    }

    func testIconsStopAfterUnavailableHelper() async throws {
        let packages = try (0 ..< 17).map {
            try ADBTVInstalledPackage(packageName: "com.example.app\($0)")
        }
        var session = InstalledAppSession(outputs: [checkedOutput("helper unavailable")])

        let icons = await ADBTVInstalledAppManager().icons(for: packages, using: &session)

        XCTAssertTrue(icons.isEmpty)
        XCTAssertEqual(session.commands.count, 1)
    }

    func testIconRejectsOversizedAndInvalidDimensions() throws {
        XCTAssertThrowsError(try ADBTVInstalledAppIcon(
            pngData: Data(repeating: 0, count: ADBTVInstalledAppIcon.maximumPNGByteCount + 1)
        )) {
            XCTAssertEqual(
                $0 as? ADBTVInstalledAppError,
                .iconPNGTooLarge(ADBTVInstalledAppIcon.maximumPNGByteCount + 1)
            )
        }

        var header = Array(try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64)).prefix(24))
        header.replaceSubrange(16 ..< 20, with: [0, 0, 1, 0])
        XCTAssertThrowsError(try ADBTVInstalledAppIcon(pngData: Data(header))) {
            XCTAssertEqual(
                $0 as? ADBTVInstalledAppError,
                .invalidIconDimensions(width: 256, height: 1)
            )
        }
    }

    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}

private struct InstalledAppSession: ADBShellCommandRunningSession {
    var outputs: [ADBShellOutput]
    var commands: [String] = []

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        commands.append(command.rawValue)
        return outputs.removeFirst()
    }
}

private func checkedOutput(_ value: String, exitCode: Int = 0) -> ADBShellOutput {
    ADBShellOutput(bytes: Array(
        (value + "\n\(ADBCheckedShellInvocation.exitStatusMarker)\(exitCode)\n").utf8
    ))
}
