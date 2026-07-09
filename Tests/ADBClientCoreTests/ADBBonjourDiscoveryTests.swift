import XCTest
@testable import ADBClientCore

final class ADBBonjourDiscoveryTests: XCTestCase {
    func testWirelessDebuggingServiceKindsExposeBonjourTypes() {
        XCTAssertEqual(ADBWirelessDebuggingServiceKind.pairing.bonjourType, "_adb-tls-pairing._tcp")
        XCTAssertEqual(ADBWirelessDebuggingServiceKind.connect.bonjourType, "_adb-tls-connect._tcp")
        XCTAssertEqual(
            ADBWirelessDebuggingServiceKind(bonjourType: "_adb-tls-pairing._tcp"),
            .pairing
        )
        XCTAssertEqual(
            ADBWirelessDebuggingServiceKind(bonjourType: "_adb-tls-connect._tcp"),
            .connect
        )
        XCTAssertNil(ADBWirelessDebuggingServiceKind(bonjourType: "_ssh._tcp"))
    }

    func testDiscoveredServiceBuildsStableIdentityAndKind() {
        let service = ADBDiscoveredService(
            serviceName: "Living Room TV",
            serviceType: "_adb-tls-connect._tcp",
            domain: "local.",
            interfaceName: "en0"
        )

        XCTAssertEqual(service.id, "_adb-tls-connect._tcp|local.|en0|Living Room TV")
        XCTAssertEqual(service.kind, .connect)
        XCTAssertEqual(service.displayName, "Living Room TV")
    }

    func testDiscoverySnapshotSortsServicesForPresentation() {
        let services = [
            ADBDiscoveredService(serviceName: "Bedroom", serviceType: "_adb-tls-connect._tcp", domain: "local."),
            ADBDiscoveredService(serviceName: "Living Room", serviceType: "_adb-tls-pairing._tcp", domain: "local."),
            ADBDiscoveredService(serviceName: "Kitchen", serviceType: "_adb-tls-connect._tcp", domain: "local.")
        ]

        let snapshot = ADBBonjourDiscoverySnapshot(services: services)

        XCTAssertEqual(snapshot.services.map(\.serviceName), [
            "Bedroom",
            "Kitchen",
            "Living Room"
        ])
    }
}
