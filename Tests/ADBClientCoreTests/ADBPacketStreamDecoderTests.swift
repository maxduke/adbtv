import XCTest
@testable import ADBClientCore

final class ADBPacketStreamDecoderTests: XCTestCase {
    func testBuffersPartialFrames() throws {
        let packet = ADBPacket(command: .okay, arg0: 1, arg1: 2)
        let encoded = try packet.encoded()
        var decoder = ADBPacketStreamDecoder()

        let firstResult = try decoder.append(Array(encoded.prefix(10)))
        let secondResult = try decoder.append(Array(encoded.dropFirst(10)))

        XCTAssertEqual(firstResult, [])
        XCTAssertEqual(secondResult, [packet])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testDecodesMultipleFramesFromOneAppend() throws {
        let first = ADBPacket(command: .okay, arg0: 1, arg1: 2)
        let second = ADBPacket(command: .close, arg0: 3, arg1: 4)
        let bytes = try first.encoded() + (try second.encoded())
        var decoder = ADBPacketStreamDecoder()

        let packets = try decoder.append(bytes)

        XCTAssertEqual(packets, [first, second])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testRejectsOversizedPayloadBeforeBufferingIt() throws {
        var header = try ADBPacket(command: .write, arg0: 1, arg1: 2).encoded()
        let payloadByteCount = UInt32(ADBPacket.maximumPayloadByteCount + 1)
        header.replaceSubrange(12 ..< 16, with: [
            UInt8(payloadByteCount & 0xff),
            UInt8((payloadByteCount >> 8) & 0xff),
            UInt8((payloadByteCount >> 16) & 0xff),
            UInt8((payloadByteCount >> 24) & 0xff)
        ])
        var decoder = ADBPacketStreamDecoder()

        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(
                error as? ADBPacketFramingError,
                .payloadTooLarge(Int(payloadByteCount))
            )
        }
        XCTAssertEqual(decoder.bufferedByteCount, header.count)
    }
}
