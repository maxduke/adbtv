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

    func testPairingPacketHeaderEncodesBigEndianPayloadSize() throws {
        let header = try ADBPairingPacketHeader(type: .spake2Message, payloadSize: 0x0102_0304)

        XCTAssertEqual(header.encoded(), [1, 0, 1, 2, 3, 4])
        XCTAssertEqual(try ADBPairingPacketHeader(encodedBytes: [1, 0, 1, 2, 3, 4]), header)
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

    func testPairingPeerInfoEncodesTypeAndPaddedData() throws {
        let peerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [1, 2, 3])
        let encoded = peerInfo.encoded()

        XCTAssertEqual(encoded.count, ADBPairingPeerInfo.encodedByteCount)
        XCTAssertEqual(Array(encoded.prefix(5)), [0, 1, 2, 3, 0])
        XCTAssertEqual(try ADBPairingPeerInfo(encodedBytes: encoded), peerInfo)
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
}
