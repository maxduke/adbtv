#if canImport(Network) && canImport(Security)
@testable import ADBClientCore
import Dispatch
import Network
import Security
import XCTest

final class ADBPairingTLSConnectionTests: XCTestCase {
    func testExporterConstantsMatchAOSPChannelBinding() {
        XCTAssertEqual(
            ADBPairingTLSConnection.exporterLabel,
            Array("adb-label".utf8) + [0]
        )
        XCTAssertEqual(ADBPairingTLSConnection.exporterByteCount, 64)
    }

    func testParametersContainTLSOverTCP() throws {
        let identity = try makeAuthenticationIdentity().pairingIdentity()
        let parameters = ADBPairingTLSConnection.parameters(
            identity: identity,
            verifyQueue: DispatchQueue(label: "ADBPairingTLSConnectionTests")
        )

        XCTAssertTrue(parameters.defaultProtocolStack.transportProtocol is NWProtocolTCP.Options)
        XCTAssertTrue(
            parameters.defaultProtocolStack.applicationProtocols.contains {
                $0 is NWProtocolTLS.Options
            }
        )
    }

    private func makeAuthenticationIdentity() throws -> ADBAppleAuthenticationIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return ADBAppleAuthenticationIdentity(privateKey: key)
    }
}
#endif
