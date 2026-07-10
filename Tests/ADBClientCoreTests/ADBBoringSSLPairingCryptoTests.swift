#if canImport(CryptoKit)
@testable import ADBClientCore
import XCTest

final class ADBBoringSSLPairingCryptoTests: XCTestCase {
    func testClientAndServerDeriveInteroperableSequencedCiphers() throws {
        let password = Array("123456".utf8) + (0 ..< 64).map(UInt8.init)
        let client = try ADBBoringSSLPairingKeyExchange(role: .client, password: password)
        let server = try ADBBoringSSLPairingKeyExchange(role: .server, password: password)

        let clientMessage = try client.localSPAKE2Message()
        let serverMessage = try server.localSPAKE2Message()
        XCTAssertEqual(clientMessage.count, 32)
        XCTAssertEqual(serverMessage.count, 32)

        let clientCipher = try client.initializeCipher(peerSPAKE2Message: serverMessage)
        let serverCipher = try server.initializeCipher(peerSPAKE2Message: clientMessage)

        let firstClientPlaintext = Array("first client message".utf8)
        let secondClientPlaintext = Array("second client message".utf8)
        XCTAssertEqual(
            try serverCipher.decrypt(clientCipher.encrypt(firstClientPlaintext)),
            firstClientPlaintext
        )
        XCTAssertEqual(
            try serverCipher.decrypt(clientCipher.encrypt(secondClientPlaintext)),
            secondClientPlaintext
        )

        let serverPlaintext = Array("server message".utf8)
        XCTAssertEqual(
            try clientCipher.decrypt(serverCipher.encrypt(serverPlaintext)),
            serverPlaintext
        )
    }

    func testWrongPasswordProducesUnauthenticCiphertext() throws {
        let exporter = (0 ..< 64).map(UInt8.init)
        let client = try ADBBoringSSLPairingKeyExchange(
            role: .client,
            password: Array("123456".utf8) + exporter
        )
        let server = try ADBBoringSSLPairingKeyExchange(
            role: .server,
            password: Array("654321".utf8) + exporter
        )

        let clientMessage = try client.localSPAKE2Message()
        let serverMessage = try server.localSPAKE2Message()
        let clientCipher = try client.initializeCipher(peerSPAKE2Message: serverMessage)
        let serverCipher = try server.initializeCipher(peerSPAKE2Message: clientMessage)

        let ciphertext = try clientCipher.encrypt(Array("peer info".utf8))
        XCTAssertThrowsError(try serverCipher.decrypt(ciphertext)) { error in
            XCTAssertEqual(error as? ADBPairingCryptoError, .decryptionFailed)
        }
    }

    func testPublicInitializerRequiresAOSPExporterLength() throws {
        let secret = try ADBPairingSecret(code: ADBPairingCode("123456"))

        XCTAssertThrowsError(try ADBBoringSSLPairingKeyExchange(
            secret: secret,
            tlsExporter: Array(repeating: 0, count: 63)
        )) { error in
            XCTAssertEqual(
                error as? ADBPairingCryptoError,
                .invalidTLSExporterByteCount(63)
            )
        }

        let keyExchange = try ADBBoringSSLPairingKeyExchange(
            secret: secret,
            tlsExporter: Array(repeating: 0, count: 64)
        )
        XCTAssertEqual(try keyExchange.localSPAKE2Message().count, 32)
    }

    func testKeyExchangeRejectsInvalidStateAndPeerMessage() throws {
        let exchange = try ADBBoringSSLPairingKeyExchange(
            role: .client,
            password: Array("password".utf8)
        )

        XCTAssertThrowsError(try exchange.initializeCipher(peerSPAKE2Message: [])) { error in
            XCTAssertEqual(error as? ADBPairingCryptoError, .localMessageNotRead)
        }

        _ = try exchange.localSPAKE2Message()
        XCTAssertThrowsError(try exchange.localSPAKE2Message()) { error in
            XCTAssertEqual(error as? ADBPairingCryptoError, .localMessageAlreadyRead)
        }
        XCTAssertThrowsError(try exchange.initializeCipher(peerSPAKE2Message: [1, 2, 3])) { error in
            XCTAssertEqual(error as? ADBPairingCryptoError, .invalidPeerMessageByteCount(3))
        }
    }
}
#endif
