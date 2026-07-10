#if canImport(Security)
import XCTest
@testable import ADBClientCore

final class ADBAppleAuthenticationIdentityTests: XCTestCase {
    func testStoreUsesSynchronizableKeychainIdentityByDefault() {
        XCTAssertTrue(ADBAppleAuthenticationIdentityStore().synchronizable)
    }

    func testStoreKeepsConfiguration() {
        let store = ADBAppleAuthenticationIdentityStore(
            applicationTag: "com.adbtv.tests.identity",
            publicKeyComment: "tester@adbtv",
            synchronizable: false
        )

        XCTAssertEqual(store.applicationTag, "com.adbtv.tests.identity")
        XCTAssertEqual(store.publicKeyComment, "tester@adbtv")
        XCTAssertFalse(store.synchronizable)
    }

    func testAuthenticationIdentityCreatesMatchingTLSIdentityAndPairingMaterial() throws {
        let authenticationIdentity = ADBAppleAuthenticationIdentity(
            privateKey: try makePrivateKey(),
            publicKeyComment: "tester@adbtv"
        )

        let pairingIdentity = try authenticationIdentity.pairingIdentity()
        XCTAssertEqual(
            pairingIdentity.material.peerInfo,
            try ADBPairingPeerInfo(authenticationPublicKey: authenticationIdentity.publicKey())
        )
        XCTAssertTrue(
            String(decoding: pairingIdentity.material.certificatePEM, as: UTF8.self)
                .hasPrefix("-----BEGIN CERTIFICATE-----\n")
        )
        XCTAssertTrue(
            String(decoding: pairingIdentity.material.privateKeyPEM, as: UTF8.self)
                .hasPrefix("-----BEGIN RSA PRIVATE KEY-----\n")
        )

        var recoveredPrivateKey: SecKey?
        XCTAssertEqual(
            SecIdentityCopyPrivateKey(
                pairingIdentity.appleIdentity,
                &recoveredPrivateKey
            ),
            errSecSuccess
        )
        XCTAssertNotNil(recoveredPrivateKey)
    }

    private func makePrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return key
    }
}
#endif
