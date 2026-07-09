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
}
