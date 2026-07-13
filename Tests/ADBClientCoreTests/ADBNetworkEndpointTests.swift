#if canImport(Network)
import Network
import XCTest
@testable import ADBClientCore

final class ADBNetworkEndpointTests: XCTestCase {
    func testEndpointStoresHostAndPort() {
        let endpoint = ADBNetworkEndpoint(host: "192.168.1.50", port: 5555)

        XCTAssertEqual(endpoint.host, "192.168.1.50")
        XCTAssertEqual(endpoint.port, 5555)
    }

    func testEndpointIsEquatable() {
        XCTAssertEqual(
            ADBNetworkEndpoint(host: "android-tv.local", port: 5555),
            ADBNetworkEndpoint(host: "android-tv.local", port: 5555)
        )
        XCTAssertNotEqual(
            ADBNetworkEndpoint(host: "android-tv.local", port: 5555),
            ADBNetworkEndpoint(host: "android-tv.local", port: 37099)
        )
    }

    func testNetworkTargetBuildsHostPortEndpoint() {
        let target = ADBNetworkTarget.hostPort(
            ADBNetworkEndpoint(host: "android-tv.local", port: 5555)
        )

        guard case let .hostPort(host, port) = target.nwEndpoint else {
            return XCTFail("Expected a host-port endpoint.")
        }

        XCTAssertEqual(host, NWEndpoint.Host("android-tv.local"))
        XCTAssertEqual(port.rawValue, 5555)
    }

    func testNetworkTargetBuildsBonjourServiceEndpoint() {
        let service = ADBDiscoveredService(
            serviceName: "adb-serial-guid",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local.",
            interfaceName: "en0"
        )
        let target = ADBNetworkTarget.bonjourService(service)

        guard case let .service(name, type, domain, interface) = target.nwEndpoint else {
            return XCTFail("Expected a Bonjour service endpoint.")
        }

        XCTAssertEqual(name, service.serviceName)
        XCTAssertEqual(type, service.serviceType)
        XCTAssertEqual(domain, service.domain)
        XCTAssertNil(interface)
    }
}
#endif
