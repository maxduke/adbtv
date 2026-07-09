import XCTest
@testable import ADBClientCore

final class ADBPacketTests: XCTestCase {
    func testEncodeAndDecodeRoundTrip() throws {
        let payload = Array("host::".utf8) + [0]
        let packet = ADBPacket(command: .connect, arg0: 0x0100_0000, arg1: 4096, payload: payload)

        let encoded = try packet.encoded()
        let decoded = try ADBPacket.decodeFrame(from: encoded)

        XCTAssertEqual(decoded.packet, packet)
        XCTAssertEqual(decoded.consumedByteCount, ADBPacket.headerLength + payload.count)
    }

    func testEncodedHeaderUsesLittleEndianADBFields() throws {
        let packet = ADBPacket(command: .connect, arg0: 1, arg1: 2, payload: [1, 2, 3])
        let encoded = try packet.encoded()

        XCTAssertEqual(Array(encoded[0..<4]), Array("CNXN".utf8))
        XCTAssertEqual(Array(encoded[4..<8]), [1, 0, 0, 0])
        XCTAssertEqual(Array(encoded[8..<12]), [2, 0, 0, 0])
        XCTAssertEqual(Array(encoded[12..<16]), [3, 0, 0, 0])
        XCTAssertEqual(Array(encoded[16..<20]), [6, 0, 0, 0])
    }

    func testDecodeRejectsInvalidMagic() throws {
        var encoded = try ADBPacket(command: .connect, arg0: 0, arg1: 0).encoded()
        encoded[20] = 0
        let corruptedMagic = (ADBCommand.connect.rawValue ^ 0xffff_ffff) & 0xffff_ff00

        XCTAssertThrowsError(try ADBPacket.decodeFrame(from: encoded)) { error in
            XCTAssertEqual(
                error as? ADBPacketFramingError,
                .invalidMagic(expected: corruptedMagic, actual: ADBCommand.connect.rawValue ^ 0xffff_ffff)
            )
        }
    }

    func testDecodeRejectsInvalidChecksum() throws {
        var encoded = try ADBPacket(command: .write, arg0: 1, arg1: 2, payload: [1, 2, 3]).encoded()
        encoded[16] = 7

        XCTAssertThrowsError(try ADBPacket.decodeFrame(from: encoded)) { error in
            XCTAssertEqual(
                error as? ADBPacketFramingError,
                .invalidChecksum(expected: 7, actual: 6)
            )
        }
    }

    func testDecodeReportsIncompletePayload() throws {
        var encoded = try ADBPacket(command: .write, arg0: 1, arg1: 2, payload: [1, 2, 3]).encoded()
        encoded.removeLast()

        XCTAssertThrowsError(try ADBPacket.decodeFrame(from: encoded)) { error in
            XCTAssertEqual(
                error as? ADBPacketFramingError,
                .incompletePayload(expectedByteCount: 3, actualByteCount: 2)
            )
        }
    }
}
