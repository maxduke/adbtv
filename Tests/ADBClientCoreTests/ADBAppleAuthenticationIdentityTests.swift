#if canImport(Security)
import XCTest
@testable import ADBClientCore

final class ADBAppleAuthenticationIdentityTests: XCTestCase {
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
        let applicationTag = "com.adbtv.tests.identity.\(UUID().uuidString)"
        defer { deleteKey(applicationTag: applicationTag) }
        let store = ADBAppleAuthenticationIdentityStore(
            applicationTag: applicationTag,
            publicKeyComment: "tester@adbtv",
            synchronizable: false
        )
        let authenticationIdentity = try store.createIdentity()

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
                sec_identity_copy_ref(pairingIdentity.securityIdentity),
                &recoveredPrivateKey
            ),
            errSecSuccess
        )
        XCTAssertNotNil(recoveredPrivateKey)
    }

    private func deleteKey(applicationTag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrApplicationTag as String: Data(applicationTag.utf8)
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
