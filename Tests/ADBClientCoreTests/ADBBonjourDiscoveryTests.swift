import XCTest
@testable import ADBClientCore

final class ADBBonjourDiscoveryTests: XCTestCase {
    func testDiscoveryFailureClassifiesBonjourAuthorizationErrors() {
        XCTAssertEqual(
            ADBBonjourDiscoveryFailure(
                dnsErrorCode: -65_555,
                diagnosticDescription: "NoAuth"
            ).reason,
            .noAuthorization
        )
        XCTAssertEqual(
            ADBBonjourDiscoveryFailure(
                dnsErrorCode: -65_570,
                diagnosticDescription: "PolicyDenied"
            ).reason,
            .localNetworkDenied
        )
        XCTAssertEqual(
            ADBBonjourDiscoveryFailure(
                dnsErrorCode: -65_540,
                diagnosticDescription: "BadParam"
            ).reason,
            .other
        )
    }

    func testBrowserStateCarriesRecoverableAuthorizationDetail() {
        let failure = ADBBonjourDiscoveryFailure(
            dnsErrorCode: -65_555,
            diagnosticDescription: "NoAuth"
        )

        XCTAssertEqual(
            ADBBonjourDiscoveryBrowserState.waitingForAuthorization(failure),
            .waitingForAuthorization(failure)
        )
        XCTAssertEqual(ADBBonjourDiscoveryBrowserState.ready, .ready)
    }

    func testWirelessDebuggingServiceKindsExposeBonjourTypes() {
#if canImport(Network)
        XCTAssertEqual(ADBBonjourServiceBrowser.localDomain, "local.")
#endif
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

    func testDiscoverySnapshotReplacesOneServiceKindAndRemovesStaleResults() {
        let connectService = ADBDiscoveredService(
            serviceName: "adb-connect-guid",
            serviceType: ADBWirelessDebuggingServiceKind.connect.bonjourType,
            domain: "local."
        )
        let stalePairingService = ADBDiscoveredService(
            serviceName: "adb-old-guid",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        let currentPairingService = ADBDiscoveredService(
            serviceName: "adb-current-guid",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        var snapshot = ADBBonjourDiscoverySnapshot(services: [
            connectService,
            stalePairingService
        ])

        snapshot.replaceServices(of: .pairing, with: [currentPairingService])

        XCTAssertEqual(snapshot.services, [connectService, currentPairingService])

        snapshot.replaceServices(of: .pairing, with: [])

        XCTAssertEqual(snapshot.services, [connectService])
    }
}
