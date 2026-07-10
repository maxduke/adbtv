import Foundation
import XCTest

final class ADBTVAppMetadataTests: XCTestCase {
    func testInfoPlistDeclaresRequiredNetworkAndCameraConfiguration() throws {
        let infoPlistURL = packageRoot
            .appendingPathComponent("Apps")
            .appendingPathComponent("ADBTViOS")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let appTransportSecurity = try XCTUnwrap(
            propertyList["NSAppTransportSecurity"] as? [String: Any]
        )
        XCTAssertEqual(appTransportSecurity["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertNil(appTransportSecurity["NSAllowsLocalNetworking"])

        XCTAssertEqual(
            propertyList["NSBonjourServices"] as? [String],
            ["_adb-tls-pairing._tcp", "_adb-tls-connect._tcp"]
        )
        XCTAssertFalse(try XCTUnwrap(propertyList["NSCameraUsageDescription"] as? String).isEmpty)
        XCTAssertFalse(try XCTUnwrap(propertyList["NSLocalNetworkUsageDescription"] as? String).isEmpty)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
