import XCTest
@testable import ADBTVApp

final class ADBTVOpenSourceNoticesTests: XCTestCase {
    func testBundledNoticesIdentifyDistributedCodeAndLicenseTerms() throws {
        let notices = try ADBTVOpenSourceNotices.loadBundledText()
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectLicense = try String(
            contentsOf: repositoryRoot.appendingPathComponent("LICENSE"),
            encoding: .utf8
        )

        XCTAssertTrue(notices.hasPrefix("ADB TV Legal Notices\n"))
        XCTAssertTrue(notices.contains("Source: https://github.com/maxduke/adbtv"))
        XCTAssertTrue(notices.contains(projectLicense))
        XCTAssertTrue(notices.contains("Copyright (c) 2026 maxduke"))
        XCTAssertTrue(notices.contains("ADB TV Noncommercial Source License 1.0"))
        XCTAssertTrue(notices.contains("This license does not grant the right to Monetize"))
        XCTAssertTrue(notices.contains("provide the complete Corresponding Source"))
        XCTAssertTrue(notices.contains("BoringSSL SwiftPM 0.41.0"))
        XCTAssertTrue(notices.contains("Apache License\n                           Version 2.0"))
        XCTAssertTrue(notices.contains("Licenses for support code"))
    }
}
