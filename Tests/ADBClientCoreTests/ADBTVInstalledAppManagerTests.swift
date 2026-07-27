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

    func testSystemSnapshotLoadsStateAndProtectedRolesForActiveUser() async throws {
        var session = InstalledAppSession(outputs: [
            checkedOutput("10\n"),
            checkedOutput(
                """
                package:android
                package:com.example.keyboard
                package:com.example.launcher
                package:com.example.optional
                package:com.example.settings
                package:com.google.android.gms
                """
            ),
            checkedOutput("package:com.example.optional\n"),
            checkedOutput("com.example.launcher/.MainActivity\n"),
            checkedOutput("com.example.settings/.SettingsActivity\n"),
            checkedOutput("com.example.keyboard/.InputMethod\n")
        ])

        let snapshot = try await ADBTVInstalledAppManager().systemSnapshot(using: &session)
        let optional = try ADBTVInstalledPackage(packageName: "com.example.optional")

        XCTAssertEqual(snapshot.userID, 10)
        XCTAssertEqual(snapshot.state(for: optional), .disabled)
        XCTAssertTrue(snapshot.canDisablePackages)
        XCTAssertNil(snapshot.safetyCheckFailureDescription)
        XCTAssertEqual(snapshot.protectionReasons["android"], .androidCore)
        XCTAssertEqual(
            snapshot.protectionReasons["com.google.android.gms"],
            .ecosystemInfrastructure
        )
        XCTAssertEqual(
            snapshot.protectionReasons["com.example.launcher"],
            .activeLauncher
        )
        XCTAssertEqual(snapshot.protectionReasons["com.example.settings"], .settings)
        XCTAssertEqual(
            snapshot.protectionReasons["com.example.keyboard"],
            .activeInputMethod
        )
        XCTAssertTrue(session.commands[0].hasPrefix("am get-current-user; "))
        XCTAssertTrue(
            session.commands[1].hasPrefix("pm list packages -s --user 10; ")
        )
        XCTAssertTrue(
            session.commands[2].hasPrefix("pm list packages -s -d --user 10; ")
        )
        XCTAssertTrue(session.commands[3].contains("android.intent.category.HOME"))
        XCTAssertTrue(session.commands[4].contains("android.settings.SETTINGS"))
        XCTAssertTrue(
            session.commands[5].hasPrefix(
                "settings --user 10 get secure default_input_method; "
            )
        )
    }

    func testSystemSnapshotKeepsPackagesWhenProtectionChecksFail() async throws {
        var session = InstalledAppSession(outputs: [
            checkedOutput("0\n"),
            checkedOutput("package:android\npackage:com.example.optional\n"),
            checkedOutput(""),
            checkedOutput("No activity found\n")
        ])

        let snapshot = try await ADBTVInstalledAppManager().systemSnapshot(using: &session)

        XCTAssertEqual(
            snapshot.packages.map(\.packageName),
            ["android", "com.example.optional"]
        )
        XCTAssertFalse(snapshot.canDisablePackages)
        XCTAssertNotNil(snapshot.safetyCheckFailureDescription)
        XCTAssertEqual(snapshot.protectionReasons["android"], .androidCore)
    }

    func testSystemSnapshotAcceptsTVWithoutActiveInputMethod() async throws {
        var session = InstalledAppSession(outputs: [
            checkedOutput("0\n"),
            checkedOutput(
                "package:com.example.launcher\npackage:com.example.settings\n"
            ),
            checkedOutput(""),
            checkedOutput("com.example.launcher/.MainActivity\n"),
            checkedOutput("com.example.settings/.SettingsActivity\n"),
            checkedOutput("null\n")
        ])

        let snapshot = try await ADBTVInstalledAppManager().systemSnapshot(using: &session)

        XCTAssertTrue(snapshot.canDisablePackages)
        XCTAssertFalse(
            snapshot.protectionReasons.values.contains(.activeInputMethod)
        )
    }

    func testDisableUsesNumericUserAndVerifiesDisabledState() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.optional")
        var session = InstalledAppSession(outputs: [
            checkedOutput("com.example.launcher/.MainActivity\n"),
            checkedOutput("com.example.settings/.SettingsActivity\n"),
            checkedOutput("null\n"),
            checkedOutput("Package com.example.optional new state: disabled-user\n"),
            checkedOutput("package:com.example.optional\n")
        ])

        try await ADBTVInstalledAppManager().disable(
            package,
            userID: 10,
            using: &session
        )

        XCTAssertTrue(
            session.commands[3].hasPrefix(
                "pm disable-user --user 10 'com.example.optional'; "
            )
        )
        XCTAssertTrue(
            session.commands[4].hasPrefix("pm list packages -s -d --user 10; ")
        )
    }

    func testDisableRejectsProtectedPackageBeforeChangingState() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.launcher")
        var session = InstalledAppSession(outputs: [
            checkedOutput("com.example.launcher/.MainActivity\n"),
            checkedOutput("com.example.settings/.SettingsActivity\n"),
            checkedOutput("null\n")
        ])

        do {
            try await ADBTVInstalledAppManager().disable(
                package,
                userID: 0,
                using: &session
            )
            XCTFail("Expected active launcher protection.")
        } catch let error as ADBTVInstalledAppError {
            XCTAssertEqual(
                error,
                .protectedPackage(
                    packageName: package.packageName,
                    reason: .activeLauncher
                )
            )
        }
        XCTAssertEqual(session.commands.count, 3)
        XCTAssertFalse(session.commands.contains { $0.contains("pm disable-user") })
    }

    func testDisableRejectsUnchangedPackageState() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.optional")
        var session = InstalledAppSession(outputs: [
            checkedOutput("com.example.launcher/.MainActivity\n"),
            checkedOutput("com.example.settings/.SettingsActivity\n"),
            checkedOutput("null\n"),
            checkedOutput("Package com.example.optional new state: disabled-user\n"),
            checkedOutput("")
        ])

        do {
            try await ADBTVInstalledAppManager().disable(
                package,
                userID: 0,
                using: &session
            )
            XCTFail("Expected state verification to fail.")
        } catch let error as ADBTVInstalledAppError {
            XCTAssertEqual(
                error,
                .packageStateMismatch(
                    packageName: package.packageName,
                    expected: .disabled,
                    actual: .enabled
                )
            )
        }
    }

    func testRestoreDefaultReturnsAndroidEffectiveState() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.dormant")
        var session = InstalledAppSession(outputs: [
            checkedOutput("Package com.example.dormant new state: default\n"),
            checkedOutput("package:com.example.dormant\n")
        ])

        let state = try await ADBTVInstalledAppManager().restoreDefault(
            package,
            userID: 0,
            using: &session
        )

        XCTAssertEqual(state, .disabled)
        XCTAssertTrue(
            session.commands[0].hasPrefix(
                "pm default-state --user 0 'com.example.dormant'; "
            )
        )
    }

    func testDisableRejectsInvalidUserBeforeSendingCommand() async throws {
        let package = try ADBTVInstalledPackage(packageName: "com.example.optional")
        var session = InstalledAppSession(outputs: [])

        do {
            try await ADBTVInstalledAppManager().disable(
                package,
                userID: -1,
                using: &session
            )
            XCTFail("Expected user validation to fail.")
        } catch let error as ADBTVInstalledAppError {
            XCTAssertEqual(error, .invalidUserID(-1))
        }
        XCTAssertTrue(session.commands.isEmpty)
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
