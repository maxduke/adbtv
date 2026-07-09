import XCTest
@testable import ADBClientCore

final class ADBAuthenticationTests: XCTestCase {
    func testPublicKeyPayloadIsNullTerminated() throws {
        let publicKey = try ADBAuthenticationPublicKey("AAAA adb@ios")

        XCTAssertEqual(publicKey.payload, Array("AAAA adb@ios".utf8) + [0])
    }

    func testPublicKeyRejectsEmptyValue() {
        XCTAssertThrowsError(try ADBAuthenticationPublicKey("")) { error in
            XCTAssertEqual(error as? ADBAuthenticationPublicKeyError, .emptyKey)
        }
    }

    func testPublicKeyRejectsNullByte() {
        XCTAssertThrowsError(try ADBAuthenticationPublicKey("AAAA\u{0}adb@ios")) { error in
            XCTAssertEqual(error as? ADBAuthenticationPublicKeyError, .containsNullByte)
        }
    }

    func testResponderSendsSignatureBeforePublicKeyFallback() throws {
        var responder = ADBAuthenticationResponder(identity: TestAuthenticationIdentity(
            signature: [1, 2, 3],
            publicKey: try ADBAuthenticationPublicKey("AAAA adb@ios")
        ))

        let signaturePacket = try responder.responsePacket(forToken: [9, 8, 7])
        let publicKeyPacket = try responder.responsePacket(forToken: [9, 8, 7])

        XCTAssertEqual(signaturePacket, ADBPacket(
            command: .auth,
            arg0: ADBAuthenticationType.signature.rawValue,
            arg1: 0,
            payload: [1, 2, 3, 9, 8, 7]
        ))
        XCTAssertEqual(publicKeyPacket, ADBPacket(
            command: .auth,
            arg0: ADBAuthenticationType.rsaPublicKey.rawValue,
            arg1: 0,
            payload: Array("AAAA adb@ios".utf8) + [0]
        ))
    }

    func testResponderResetRetriesSignature() throws {
        var responder = ADBAuthenticationResponder(identity: TestAuthenticationIdentity(
            signature: [1, 2, 3],
            publicKey: try ADBAuthenticationPublicKey("AAAA adb@ios")
        ))

        _ = try responder.responsePacket(forToken: [9, 8, 7])
        responder.reset()
        let packet = try responder.responsePacket(forToken: [6, 5, 4])

        XCTAssertEqual(packet.arg0, ADBAuthenticationType.signature.rawValue)
        XCTAssertEqual(packet.payload, [1, 2, 3, 6, 5, 4])
    }
}
