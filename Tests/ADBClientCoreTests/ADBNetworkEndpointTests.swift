#if canImport(Network)
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
}
#endif
