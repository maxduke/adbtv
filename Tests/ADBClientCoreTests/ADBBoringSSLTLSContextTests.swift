#if canImport(Security)
import Security
import XCTest
@testable import ADBClientCore

final class ADBBoringSSLTLSContextTests: XCTestCase {
    func testClientAndServerCompleteMutualTLSAndExchangePlaintext() throws {
        let client = try ADBBoringSSLTLSContext(
            role: .client,
            identity: makeIdentityMaterial()
        )
        let server = try ADBBoringSSLTLSContext(
            role: .server,
            identity: makeIdentityMaterial()
        )

        try completeHandshake(client: client, server: server)

        XCTAssertTrue(client.hasPeerCertificate)
        XCTAssertTrue(server.hasPeerCertificate)

        let clientMessage = Array("hello from client".utf8)
        let clientWrite = try client.writePlaintext(clientMessage)
        XCTAssertEqual(clientWrite, ADBTLSWriteResult(
            operation: .complete,
            consumedByteCount: clientMessage.count
        ))
        try transferEncryptedOutput(from: client, to: server)
        XCTAssertEqual(try server.readPlaintext().bytes, clientMessage)

        let serverMessage = Array("hello from server".utf8)
        let serverWrite = try server.writePlaintext(serverMessage)
        XCTAssertEqual(serverWrite, ADBTLSWriteResult(
            operation: .complete,
            consumedByteCount: serverMessage.count
        ))
        try transferEncryptedOutput(from: server, to: client)
        XCTAssertEqual(try client.readPlaintext().bytes, serverMessage)
    }

    func testContextRejectsInvalidIdentityMaterial() throws {
        let peerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [1])
        let invalidIdentity = try ADBPairingIdentityMaterial(
            peerInfo: peerInfo,
            certificatePEM: [1],
            privateKeyPEM: [2]
        )

        XCTAssertThrowsError(try ADBBoringSSLTLSContext(
            role: .client,
            identity: invalidIdentity
        )) { error in
            XCTAssertEqual(error as? ADBTLSError, .contextCreationFailed)
        }
    }

    private func completeHandshake(
        client: ADBBoringSSLTLSContext,
        server: ADBBoringSSLTLSContext
    ) throws {
        var clientComplete = false
        var serverComplete = false

        for _ in 0 ..< 20 {
            clientComplete = try client.handshake() == .complete
            try transferEncryptedOutput(from: client, to: server)

            serverComplete = try server.handshake() == .complete
            try transferEncryptedOutput(from: server, to: client)

            if clientComplete && serverComplete {
                return
            }
        }

        XCTFail("TLS handshake did not complete within the step limit.")
    }

    private func transferEncryptedOutput(
        from source: ADBBoringSSLTLSContext,
        to destination: ADBBoringSSLTLSContext
    ) throws {
        let bytes = try source.encryptedOutput()
        if !bytes.isEmpty {
            try destination.provideEncryptedInput(bytes)
        }
    }

    private func makeIdentityMaterial() throws -> ADBPairingIdentityMaterial {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }

        return try ADBAppleAuthenticationIdentity(privateKey: key).pairingIdentity().material
    }
}
#endif
