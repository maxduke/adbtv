import XCTest
@testable import ADBClientCore

final class ADBPairingTests: XCTestCase {
    func testPairingCodeNormalizesSeparators() throws {
        XCTAssertEqual(try ADBPairingCode("123456").rawValue, "123456")
        XCTAssertEqual(try ADBPairingCode("123 456").rawValue, "123456")
        XCTAssertEqual(try ADBPairingCode("123-456").rawValue, "123456")
    }

    func testPairingCodeRejectsInvalidValues() {
        XCTAssertThrowsError(try ADBPairingCode("12345")) { error in
            XCTAssertEqual(error as? ADBPairingCodeError, .invalidDigitCount(5))
        }
        XCTAssertThrowsError(try ADBPairingCode("1234567")) { error in
            XCTAssertEqual(error as? ADBPairingCodeError, .invalidDigitCount(7))
        }
        XCTAssertThrowsError(try ADBPairingCode("12345x")) { error in
            XCTAssertEqual(error as? ADBPairingCodeError, .containsNonDigit)
        }
        XCTAssertThrowsError(try ADBPairingCode("１２３４５６")) { error in
            XCTAssertEqual(error as? ADBPairingCodeError, .containsNonDigit)
        }
    }

    func testPairingQRCodeParsesADBPayload() throws {
        let qrCode = try ADBPairingQRCode(payload: "WIFI:T:ADB;S:Living Room TV;P:pair-secret;;")

        XCTAssertEqual(qrCode.serviceName, "Living Room TV")
        XCTAssertEqual(qrCode.password, "pair-secret")
    }

    func testPairingQRCodeUnescapesWifiPayloadFields() throws {
        let qrCode = try ADBPairingQRCode(payload: #"WIFI:T:ADB;S:TV\; Room;P:pa\:ss\\word;;"#)

        XCTAssertEqual(qrCode.serviceName, "TV; Room")
        XCTAssertEqual(qrCode.password, #"pa:ss\word"#)
    }

    func testPairingQRCodeRejectsUnsupportedPayloads() {
        XCTAssertThrowsError(try ADBPairingQRCode(payload: "not a qr payload")) { error in
            XCTAssertEqual(error as? ADBPairingQRCodeError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try ADBPairingQRCode(payload: "WIFI:T:WPA;S:Network;P:secret;;")) { error in
            XCTAssertEqual(error as? ADBPairingQRCodeError, .unsupportedAuthenticationType("WPA"))
        }
        XCTAssertThrowsError(try ADBPairingQRCode(payload: "WIFI:T:ADB;P:secret;;")) { error in
            XCTAssertEqual(error as? ADBPairingQRCodeError, .missingServiceName)
        }
        XCTAssertThrowsError(try ADBPairingQRCode(payload: "WIFI:T:ADB;S:TV;;")) { error in
            XCTAssertEqual(error as? ADBPairingQRCodeError, .missingPassword)
        }
    }

    func testPairingSecretBuildsFromManualCode() throws {
        let secret = try ADBPairingSecret(code: ADBPairingCode("123 456"))

        XCTAssertEqual(secret.source, .code)
        XCTAssertEqual(secret.bytes, Array("123456".utf8))
    }

    func testPairingSecretBuildsFromQRCodePassword() throws {
        let secret = try ADBPairingSecret(qrCode: ADBPairingQRCode(
            serviceName: "Living Room TV",
            password: "pair-secret"
        ))

        XCTAssertEqual(secret.source, .qrCode(serviceName: "Living Room TV"))
        XCTAssertEqual(secret.bytes, Array("pair-secret".utf8))
    }

    func testPairingSecretRejectsInvalidRawBytes() {
        XCTAssertThrowsError(try ADBPairingSecret(source: .code, bytes: [])) { error in
            XCTAssertEqual(error as? ADBPairingSecretError, .emptySecret)
        }
        XCTAssertThrowsError(try ADBPairingSecret(source: .code, bytes: [1, 0, 2])) { error in
            XCTAssertEqual(error as? ADBPairingSecretError, .containsNullByte)
        }
    }

    func testPairingPacketHeaderEncodesBigEndianPayloadSize() throws {
        let header = try ADBPairingPacketHeader(type: .spake2Message, payloadSize: 0x0000_4000)

        XCTAssertEqual(header.encoded(), [1, 0, 0, 0, 64, 0])
        XCTAssertEqual(try ADBPairingPacketHeader(encodedBytes: [1, 0, 0, 0, 64, 0]), header)
    }

    func testPairingPacketHeaderRejectsInvalidValues() {
        XCTAssertThrowsError(try ADBPairingPacketHeader(encodedBytes: [1, 0, 0])) { error in
            XCTAssertEqual(error as? ADBPairingPacketHeaderError, .invalidByteCount(3))
        }
        XCTAssertThrowsError(try ADBPairingPacketHeader(encodedBytes: [2, 0, 0, 0, 0, 1])) { error in
            XCTAssertEqual(error as? ADBPairingPacketHeaderError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try ADBPairingPacketHeader(encodedBytes: [1, 9, 0, 0, 0, 1])) { error in
            XCTAssertEqual(error as? ADBPairingPacketHeaderError, .invalidPacketType(9))
        }
        XCTAssertThrowsError(try ADBPairingPacketHeader(type: .peerInfo, payloadSize: 0)) { error in
            XCTAssertEqual(error as? ADBPairingPacketHeaderError, .emptyPayload)
        }
        XCTAssertThrowsError(try ADBPairingPacketHeader(
            type: .peerInfo,
            payloadSize: UInt32(ADBPairingPacketHeader.maximumPayloadSize + 1)
        )) { error in
            XCTAssertEqual(
                error as? ADBPairingPacketHeaderError,
                .payloadTooLarge(UInt32(ADBPairingPacketHeader.maximumPayloadSize + 1))
            )
        }
    }

    func testPairingPacketEncodesHeaderAndPayload() throws {
        let packet = try ADBPairingPacket(type: .spake2Message, payload: [7, 8, 9])

        XCTAssertEqual(packet.encoded(), [1, 0, 0, 0, 0, 3, 7, 8, 9])
        XCTAssertEqual(try ADBPairingPacket(encodedBytes: [1, 0, 0, 0, 0, 3, 7, 8, 9]), packet)
    }

    func testPairingPacketRejectsMalformedFrames() throws {
        XCTAssertThrowsError(try ADBPairingPacket(encodedBytes: [1, 0, 0])) { error in
            XCTAssertEqual(error as? ADBPairingPacketError, .invalidByteCount(3))
        }

        let header = try ADBPairingPacketHeader(type: .spake2Message, payloadSize: 4)
        XCTAssertThrowsError(try ADBPairingPacket(header: header, payload: [1, 2, 3])) { error in
            XCTAssertEqual(
                error as? ADBPairingPacketError,
                .payloadSizeMismatch(expected: 4, actual: 3)
            )
        }

        XCTAssertThrowsError(try ADBPairingPacket(encodedBytes: [1, 0, 0, 0, 0, 4, 1, 2, 3])) { error in
            XCTAssertEqual(
                error as? ADBPairingPacketError,
                .payloadSizeMismatch(expected: 4, actual: 3)
            )
        }
    }

    func testPairingPeerInfoEncodesTypeAndPaddedData() throws {
        let peerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [1, 2, 3])
        let encoded = peerInfo.encoded()

        XCTAssertEqual(encoded.count, ADBPairingPeerInfo.encodedByteCount)
        XCTAssertEqual(Array(encoded.prefix(5)), [0, 1, 2, 3, 0])
        XCTAssertEqual(try ADBPairingPeerInfo(encodedBytes: encoded), peerInfo)
    }

    func testPairingPeerInfoCanBeBuiltFromADBPublicKey() throws {
        let publicKey = try ADBAuthenticationPublicKey("AAAA adb@ios")
        let peerInfo = try ADBPairingPeerInfo(authenticationPublicKey: publicKey)

        XCTAssertEqual(peerInfo.type, .adbRSAPublicKey)
        XCTAssertEqual(peerInfo.data, Array("AAAA adb@ios".utf8))
    }

    func testPairingPeerInfoExposesADBDeviceGUID() throws {
        let peerInfo = try ADBPairingPeerInfo(
            type: .adbDeviceGUID,
            data: Array("adb-serial-guid".utf8)
        )

        XCTAssertEqual(peerInfo.deviceGUID, "adb-serial-guid")
        XCTAssertNil(try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [1]).deviceGUID)
        XCTAssertNil(try ADBPairingPeerInfo(type: .adbDeviceGUID, data: [0xFF]).deviceGUID)
    }

    func testPairingPeerInfoRejectsInvalidValues() {
        XCTAssertThrowsError(try ADBPairingPeerInfo(encodedBytes: [0, 1, 2])) { error in
            XCTAssertEqual(error as? ADBPairingPeerInfoError, .invalidByteCount(3))
        }

        var invalidType = Array(repeating: UInt8(0), count: ADBPairingPeerInfo.encodedByteCount)
        invalidType[0] = 9
        XCTAssertThrowsError(try ADBPairingPeerInfo(encodedBytes: invalidType)) { error in
            XCTAssertEqual(error as? ADBPairingPeerInfoError, .invalidPeerInfoType(9))
        }

        XCTAssertThrowsError(try ADBPairingPeerInfo(
            type: .adbDeviceGUID,
            data: Array(repeating: 1, count: ADBPairingPeerInfo.maximumDataByteCount + 1)
        )) { error in
            XCTAssertEqual(
                error as? ADBPairingPeerInfoError,
                .dataTooLarge(ADBPairingPeerInfo.maximumDataByteCount + 1)
            )
        }
    }

    func testPairingIdentityMaterialBuildsPeerInfoFromADBPublicKey() throws {
        let identity = try ADBPairingIdentityMaterial(
            authenticationPublicKey: ADBAuthenticationPublicKey("AAAA adb@ios"),
            certificatePEM: Array("-----BEGIN CERTIFICATE-----".utf8),
            privateKeyPEM: Array("-----BEGIN PRIVATE KEY-----".utf8)
        )

        XCTAssertEqual(identity.peerInfo.type, .adbRSAPublicKey)
        XCTAssertEqual(identity.peerInfo.data, Array("AAAA adb@ios".utf8))
        XCTAssertEqual(identity.certificatePEM, Array("-----BEGIN CERTIFICATE-----".utf8))
        XCTAssertEqual(identity.privateKeyPEM, Array("-----BEGIN PRIVATE KEY-----".utf8))
    }

    func testPairingIdentityMaterialRejectsMissingPEMInputs() throws {
        let peerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [1, 2, 3])

        XCTAssertThrowsError(try ADBPairingIdentityMaterial(
            peerInfo: peerInfo,
            certificatePEM: [],
            privateKeyPEM: [1]
        )) { error in
            XCTAssertEqual(error as? ADBPairingIdentityMaterialError, .emptyCertificatePEM)
        }

        XCTAssertThrowsError(try ADBPairingIdentityMaterial(
            peerInfo: peerInfo,
            certificatePEM: [1],
            privateKeyPEM: []
        )) { error in
            XCTAssertEqual(error as? ADBPairingIdentityMaterialError, .emptyPrivateKeyPEM)
        }
    }

    func testPairingProtocolSessionExchangesSPAKE2ThenEncryptedPeerInfo() throws {
        let localPeerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [10, 11])
        let remotePeerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [20, 21])
        var session = ADBPairingProtocolSession(
            localPeerInfo: localPeerInfo,
            keyExchange: TestPairingKeyExchange(
                localMessage: [1, 2, 3],
                expectedPeerMessage: [4, 5, 6],
                cipher: TestPairingCipher()
            )
        )

        let localSPAKE2Packet = try session.start()
        XCTAssertEqual(localSPAKE2Packet.header.type, .spake2Message)
        XCTAssertEqual(localSPAKE2Packet.payload, [1, 2, 3])
        XCTAssertEqual(session.state, .waitingForSPAKE2Message)

        let peerInfoPacket = try session.handlePeerSPAKE2Packet(ADBPairingPacket(
            type: .spake2Message,
            payload: [4, 5, 6]
        ))
        XCTAssertEqual(peerInfoPacket.header.type, .peerInfo)
        XCTAssertEqual(peerInfoPacket.payload, TestPairingCipher.encryptionPrefix + localPeerInfo.encoded())
        XCTAssertEqual(session.state, .waitingForPeerInfo)

        let result = try session.handlePeerInfoPacket(ADBPairingPacket(
            type: .peerInfo,
            payload: TestPairingCipher.encryptionPrefix + remotePeerInfo.encoded()
        ))
        XCTAssertEqual(result, remotePeerInfo)
        XCTAssertEqual(session.state, .finished)
    }

    func testPairingProtocolSessionCanUseIdentityMaterialPeerInfo() throws {
        let identity = try ADBPairingIdentityMaterial(
            authenticationPublicKey: ADBAuthenticationPublicKey("AAAA adb@ios"),
            certificatePEM: [1],
            privateKeyPEM: [2]
        )
        var session = ADBPairingProtocolSession(
            identityMaterial: identity,
            keyExchange: TestPairingKeyExchange(
                localMessage: [1, 2, 3],
                expectedPeerMessage: [4, 5, 6],
                cipher: TestPairingCipher()
            )
        )

        _ = try session.start()
        let peerInfoPacket = try session.handlePeerSPAKE2Packet(ADBPairingPacket(
            type: .spake2Message,
            payload: [4, 5, 6]
        ))

        XCTAssertEqual(peerInfoPacket.payload, TestPairingCipher.encryptionPrefix + identity.peerInfo.encoded())
    }

    func testPairingProtocolSessionRejectsInvalidStateAndPacketType() throws {
        let localPeerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [10, 11])
        var session = ADBPairingProtocolSession(
            localPeerInfo: localPeerInfo,
            keyExchange: TestPairingKeyExchange(
                localMessage: [1, 2, 3],
                expectedPeerMessage: [4, 5, 6],
                cipher: TestPairingCipher()
            )
        )

        XCTAssertThrowsError(try session.handlePeerSPAKE2Packet(ADBPairingPacket(
            type: .spake2Message,
            payload: [4, 5, 6]
        ))) { error in
            XCTAssertEqual(error as? ADBPairingProtocolSessionError, .invalidState(.ready))
        }

        _ = try session.start()
        XCTAssertThrowsError(try session.handlePeerSPAKE2Packet(ADBPairingPacket(
            type: .peerInfo,
            payload: [7]
        ))) { error in
            XCTAssertEqual(
                error as? ADBPairingProtocolSessionError,
                .unexpectedPacketType(expected: .spake2Message, actual: .peerInfo)
            )
        }
    }
}

private struct TestPairingKeyExchange: ADBPairingKeyExchange {
    var localMessage: [UInt8]
    var expectedPeerMessage: [UInt8]
    var cipher: any ADBPairingCipher

    mutating func localSPAKE2Message() throws -> [UInt8] {
        localMessage
    }

    mutating func initializeCipher(peerSPAKE2Message: [UInt8]) throws -> any ADBPairingCipher {
        if peerSPAKE2Message != expectedPeerMessage {
            throw TestPairingKeyExchangeError.unexpectedPeerMessage(peerSPAKE2Message)
        }

        return cipher
    }
}

private enum TestPairingKeyExchangeError: Error, Equatable {
    case unexpectedPeerMessage([UInt8])
}

private struct TestPairingCipher: ADBPairingCipher {
    static let encryptionPrefix: [UInt8] = [0xEE]

    func encrypt(_ plaintext: [UInt8]) throws -> [UInt8] {
        Self.encryptionPrefix + plaintext
    }

    func decrypt(_ ciphertext: [UInt8]) throws -> [UInt8] {
        guard ciphertext.starts(with: Self.encryptionPrefix) else {
            throw TestPairingCipherError.missingPrefix
        }

        return Array(ciphertext.dropFirst(Self.encryptionPrefix.count))
    }
}

private enum TestPairingCipherError: Error, Equatable {
    case missingPrefix
}
