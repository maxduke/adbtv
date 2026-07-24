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

    func testListRequestsSystemPackages() async throws {
        var session = InstalledAppSession(outputs: [
            checkedOutput("package:com.android.tv.settings\n")
        ])

        let packages = try await ADBTVInstalledAppManager().list(
            scope: .system,
            using: &session
        )

        XCTAssertEqual(packages.map(\.packageName), ["com.android.tv.settings"])
        XCTAssertTrue(session.commands[0].hasPrefix("pm list packages -s; "))
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

    func testForceStopTargetsCurrentUserAndValidatedPackage() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.player")
        var session = InstalledAppSession(outputs: [checkedOutput("")])

        try await ADBTVInstalledAppManager().forceStop(package, using: &session)

        XCTAssertTrue(
            session.commands[0].hasPrefix(
                "am force-stop --user current 'com.example.player'; "
            )
        )
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

    func testDetailsLoadMetadataAndIgnoreInvalidIconsAndUnrequestedItems() async throws {
        let validPNG = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let response = """
        [
          {
            "package":"com.example.player",
            "label":"Example Player",
            "versionName":"2.4.1",
            "versionCode":20401,
            "firstInstallTime":1704067200000,
            "lastUpdateTime":1711929600000,
            "stopped":true,
            "apkBytes":52428800,
            "png":"\(validPNG.base64EncodedString())"
          },
          {"package":"com.example.invalid","label":"Invalid Icon","png":"not-base64"},
          {"package":"com.unrequested.app","label":"Unrequested"}
        ]
        """
        var session = InstalledAppSession(outputs: [checkedOutput(response)])
        let packages = [
            try ADBTVInstalledPackage(packageName: "com.example.player"),
            try ADBTVInstalledPackage(packageName: "com.example.invalid")
        ]

        let details = await ADBTVInstalledAppManager().details(for: packages, using: &session)

        XCTAssertEqual(details["com.example.player"]?.displayName, "Example Player")
        XCTAssertEqual(details["com.example.player"]?.versionName, "2.4.1")
        XCTAssertEqual(details["com.example.player"]?.versionCode, 20_401)
        XCTAssertEqual(details["com.example.player"]?.apkByteCount, 52_428_800)
        XCTAssertEqual(details["com.example.player"]?.isStopped, true)
        XCTAssertEqual(details["com.example.player"]?.icon?.pngData, validPNG)
        XCTAssertEqual(details["com.example.invalid"]?.displayName, "Invalid Icon")
        XCTAssertNil(details["com.example.invalid"]?.isStopped)
        XCTAssertNil(details["com.example.invalid"]?.icon)
        XCTAssertNil(details["com.unrequested.app"])
        XCTAssertTrue(session.commands[0].contains("content://com.maxduke.adbtv.helper.v3.apps/apps"))
        XCTAssertFalse(session.commands[0].contains("head -c"))
        XCTAssertFalse(session.commands[0].contains("2>/dev/null"))
    }

    func testDetailsRejectOversizedProviderResponse() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.player")
        let response = """
        [{"package":"com.example.player","label":"Must Not Load"}]
        """ + String(repeating: " ", count: 1024 * 1024)
        var session = InstalledAppSession(outputs: [checkedOutput(response)])

        let details = await ADBTVInstalledAppManager().details(for: [package], using: &session)

        XCTAssertTrue(details.isEmpty)
        XCTAssertEqual(session.commands.count, 1)
    }

    func testDetailsStopAfterUnavailableHelper() async throws {
        let packages = try (0 ..< 17).map {
            try ADBTVInstalledPackage(packageName: "com.example.app\($0)")
        }
        var session = InstalledAppSession(outputs: [checkedOutput("helper unavailable")])

        let details = await ADBTVInstalledAppManager().details(for: packages, using: &session)

        XCTAssertTrue(details.isEmpty)
        XCTAssertEqual(session.commands.count, 1)
    }

    func testDetailsDiscardUnsafeOrInvalidOptionalMetadata() {
        let details = ADBTVInstalledAppDetails(
            displayName: "  Example TV  ",
            versionName: "bad\nversion",
            versionCode: -1,
            firstInstallTimeMilliseconds: 0,
            lastUpdateTimeMilliseconds: 1_714_521_600_000,
            apkByteCount: 0
        )

        XCTAssertEqual(details.displayName, "Example TV")
        XCTAssertNil(details.versionName)
        XCTAssertNil(details.versionCode)
        XCTAssertNil(details.firstInstallDate)
        XCTAssertNotNil(details.lastUpdateDate)
        XCTAssertNil(details.apkByteCount)
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
