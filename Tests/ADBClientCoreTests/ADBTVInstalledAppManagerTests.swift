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
