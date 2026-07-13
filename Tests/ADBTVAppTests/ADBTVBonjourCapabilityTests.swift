import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVBonjourCapabilityTests: XCTestCase {
    func testAvailableCapabilityStartsDiscoveryByDefault() {
        let capability = ADBTVBonjourCapability(isAvailable: true)

        XCTAssertTrue(capability.isAvailable)
        XCTAssertTrue(capability.automaticallyStartsDiscovery)
    }

    func testAvailableCapabilityCanDisableAutomaticDiscovery() {
        let capability = ADBTVBonjourCapability(
            isAvailable: true,
            automaticallyStartsDiscovery: false
        )

        XCTAssertTrue(capability.isAvailable)
        XCTAssertFalse(capability.automaticallyStartsDiscovery)
    }

    func testUnavailableCapabilityCannotStartDiscovery() {
        let capability = ADBTVBonjourCapability(
            isAvailable: false,
            automaticallyStartsDiscovery: true
        )

        XCTAssertFalse(capability.isAvailable)
        XCTAssertFalse(capability.automaticallyStartsDiscovery)
    }

    func testEntitlementValueRequiresBooleanTrue() {
        XCTAssertTrue(ADBTVBonjourCapability.isEnabled(entitlementValue: true))
        XCTAssertFalse(ADBTVBonjourCapability.isEnabled(entitlementValue: false))
        XCTAssertFalse(ADBTVBonjourCapability.isEnabled(entitlementValue: "true"))
        XCTAssertFalse(ADBTVBonjourCapability.isEnabled(entitlementValue: nil))
    }
}
