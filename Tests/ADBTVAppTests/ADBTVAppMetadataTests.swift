import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

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
        XCTAssertEqual(
            propertyList[ADBTVBonjourCapability.configurationKey] as? String,
            "$(ADBTV_BONJOUR_DISCOVERY_ENABLED)"
        )
        XCTAssertFalse(try XCTUnwrap(propertyList["NSCameraUsageDescription"] as? String).isEmpty)
        XCTAssertFalse(try XCTUnwrap(propertyList["NSLocalNetworkUsageDescription"] as? String).isEmpty)
        XCTAssertNotNil(propertyList["UILaunchScreen"] as? [String: Any])
        XCTAssertEqual(propertyList["UIRequiresFullScreen"] as? Bool, true)
        XCTAssertEqual(
            propertyList["UISupportedInterfaceOrientations"] as? [String],
            ["UIInterfaceOrientationPortrait"]
        )
        XCTAssertEqual(
            propertyList["UISupportedInterfaceOrientations~ipad"] as? [String],
            ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"]
        )

        let importedTypes = try XCTUnwrap(propertyList["UTImportedTypeDeclarations"] as? [[String: Any]])
        let apkType = try XCTUnwrap(importedTypes.first {
            $0["UTTypeIdentifier"] as? String == "com.android.package-archive"
        })
        let tags = try XCTUnwrap(apkType["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["apk"])
        XCTAssertEqual(tags["public.mime-type"] as? String, "application/vnd.android.package-archive")
    }

    func testAppIconCatalogContainsOpaqueUniversalIcon() throws {
        let appIconDirectory = packageRoot
            .appendingPathComponent("Apps/ADBTViOS/Assets.xcassets/AppIcon.appiconset")
        let contentsData = try Data(contentsOf: appIconDirectory.appendingPathComponent("Contents.json"))
        let contents = try XCTUnwrap(
            JSONSerialization.jsonObject(with: contentsData) as? [String: Any]
        )
        let images = try XCTUnwrap(contents["images"] as? [[String: String]])
        let universalIcon = try XCTUnwrap(images.first)

        XCTAssertEqual(universalIcon["filename"], "ADBTV-AppIcon.png")
        XCTAssertEqual(universalIcon["idiom"], "universal")
        XCTAssertEqual(universalIcon["platform"], "ios")
        XCTAssertEqual(universalIcon["size"], "1024x1024")

        let iconData = try Data(contentsOf: appIconDirectory.appendingPathComponent("ADBTV-AppIcon.png"))
        XCTAssertEqual(Array(iconData.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(iconData.bigEndianUInt32(at: 16), 1024)
        XCTAssertEqual(iconData.bigEndianUInt32(at: 20), 1024)
        XCTAssertEqual(iconData[24], 8)
        XCTAssertEqual(iconData[25], 2, "The app icon must be RGB without an alpha channel.")
    }

    func testBundledUnicodeInputHelperIsAnXcodeResource() throws {
        let helperURL = packageRoot.appendingPathComponent(
            "Apps/ADBTViOS/Resources/ADBTVInput.apk"
        )
        let helperData = try Data(contentsOf: helperURL)
        XCTAssertEqual(Array(helperData.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertNoThrow(try ADBAPKValidator().validate(contents: Array(helperData)))

        let project = try String(
            contentsOf: packageRoot.appendingPathComponent("ADBTV.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("ADBTVInput.apk in Resources"))
        XCTAssertEqual(
            project.components(separatedBy: "ADBTV_BONJOUR_DISCOVERY_ENABLED = NO;").count - 1,
            2
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension Data {
    func bigEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else {
            return nil
        }

        return self[offset ..< offset + 4].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
    }
}
