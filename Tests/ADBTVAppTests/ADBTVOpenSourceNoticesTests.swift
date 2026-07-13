import XCTest
@testable import ADBTVApp

final class ADBTVOpenSourceNoticesTests: XCTestCase {
    func testBundledNoticesIdentifyDistributedCodeAndLicenseTerms() throws {
        let notices = try ADBTVOpenSourceNotices.loadBundledText()

        XCTAssertTrue(notices.hasPrefix("ADB TV Open Source Notices\n"))
        XCTAssertTrue(notices.contains("Copyright (c) 2026 maxduke"))
        XCTAssertTrue(notices.contains("MIT License"))
        XCTAssertTrue(notices.contains("BoringSSL SwiftPM 0.41.0"))
        XCTAssertTrue(notices.contains("Apache License\n                           Version 2.0"))
        XCTAssertTrue(notices.contains("Licenses for support code"))
    }
}
