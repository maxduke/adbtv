import Foundation
import XCTest
@testable import ADBClientCore

final class ADBRSAKeyEncodingTests: XCTestCase {
    func testAndroidPublicKeyBinaryUsesADBLayout() throws {
        let components = try ADBRSAPublicKeyComponents(modulus: [3], exponent: 65_537)

        let binary = try ADBRSAKeyEncoder.androidPublicKeyBinary(components: components)

        XCTAssertEqual(binary.count, ADBRSAKeyEncoder.androidPublicKeyByteCount)
        XCTAssertEqual(Array(binary[0..<4]), [64, 0, 0, 0])
        XCTAssertEqual(Array(binary[4..<8]), [0x55, 0x55, 0x55, 0x55])
        XCTAssertEqual(binary[8], 3)
        XCTAssertEqual(Set(binary[9..<264]), Set<UInt8>([0]))
        XCTAssertEqual(binary[264], 1)
        XCTAssertEqual(Set(binary[265..<520]), Set<UInt8>([0]))
        XCTAssertEqual(Array(binary[520..<524]), [1, 0, 1, 0])
    }

    func testAndroidPublicKeyStringIsBase64WithComment() throws {
        let components = try ADBRSAPublicKeyComponents(modulus: [3], exponent: 65_537)

        let publicKey = try ADBRSAKeyEncoder.androidPublicKey(
            components: components,
            comment: "adbtv@ios"
        )
        let parts = publicKey.rawValue.split(separator: " ")

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].count, 700)
        XCTAssertEqual(parts[1], "adbtv@ios")
        XCTAssertNotNil(Data(base64Encoded: String(parts[0])))
    }

    func testComponentsRejectEvenModulus() {
        XCTAssertThrowsError(try ADBRSAPublicKeyComponents(modulus: [2], exponent: 65_537)) { error in
            XCTAssertEqual(error as? ADBRSAKeyEncodingError, .evenModulus)
        }
    }

    func testComponentsRejectUnsupportedExponent() {
        XCTAssertThrowsError(try ADBRSAPublicKeyComponents(modulus: [3], exponent: 17)) { error in
            XCTAssertEqual(error as? ADBRSAKeyEncodingError, .unsupportedExponent(17))
        }
    }

    func testParsesPKCS1DERPublicKey() throws {
        let der: [UInt8] = [
            0x30, 0x0a,
            0x02, 0x03, 0x00, 0x80, 0x01,
            0x02, 0x03, 0x01, 0x00, 0x01
        ]

        let components = try ADBRSAKeyEncoder.componentsFromDEREncodedPublicKey(der)

        XCTAssertEqual(components.modulus, [0x80, 0x01])
        XCTAssertEqual(components.exponent, 65_537)
    }

    func testParsesSubjectPublicKeyInfoDERPublicKey() throws {
        let pkcs1: [UInt8] = [
            0x30, 0x0a,
            0x02, 0x03, 0x00, 0x80, 0x01,
            0x02, 0x03, 0x01, 0x00, 0x01
        ]
        let algorithmIdentifier: [UInt8] = [
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00
        ]
        let bitString: [UInt8] = [0x03, UInt8(pkcs1.count + 1), 0x00] + pkcs1
        let der: [UInt8] = [0x30, UInt8(algorithmIdentifier.count + bitString.count)]
            + algorithmIdentifier
            + bitString

        let components = try ADBRSAKeyEncoder.componentsFromDEREncodedPublicKey(der)

        XCTAssertEqual(components.modulus, [0x80, 0x01])
        XCTAssertEqual(components.exponent, 65_537)
    }
}
