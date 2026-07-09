#if canImport(Network)
import XCTest
@testable import ADBClientCore

final class ADBDeviceConnectionTests: XCTestCase {
    func testNetworkConnectionStartsIdle() {
        let connection = ADBDeviceConnection(endpoint: ADBNetworkEndpoint(host: "192.168.1.50", port: 5555))

        XCTAssertEqual(connection.connectionPhase, .idle)
    }

    func testNetworkConnectionAcceptsAuthenticationIdentity() throws {
        let connection = ADBDeviceConnection(
            endpoint: ADBNetworkEndpoint(host: "192.168.1.50", port: 5555),
            authenticationIdentity: TestAuthenticationIdentity(
                signature: [1, 2, 3],
                publicKeyValue: try ADBAuthenticationPublicKey("AAAA adb@ios")
            )
        )

        XCTAssertEqual(connection.connectionPhase, .idle)
    }
}
#endif
