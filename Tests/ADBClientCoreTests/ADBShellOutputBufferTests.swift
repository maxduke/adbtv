import XCTest
@testable import ADBClientCore

final class ADBShellOutputBufferTests: XCTestCase {
    func testCollectsStreamDataUntilClose() throws {
        var buffer = ADBShellOutputBuffer(localID: 1)

        let first = try buffer.receive(.streamData(localID: 1, remoteID: 42, payload: Array("Sony ".utf8)))
        let second = try buffer.receive(.streamData(localID: 1, remoteID: 42, payload: Array("TV\n".utf8)))
        let output = try buffer.receive(.streamClosed(localID: 1, remoteID: 42))

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(buffer.utf8String, "Sony TV\n")
        XCTAssertEqual(output?.utf8String, "Sony TV\n")
        XCTAssertTrue(buffer.isClosed)
    }

    func testIgnoresNonDataLifecycleEvents() throws {
        var buffer = ADBShellOutputBuffer(localID: 1)

        XCTAssertNil(try buffer.receive(.connected(protocolVersion: 1, maxData: 4096, banner: "device::")))
        XCTAssertNil(try buffer.receive(.streamReady(localID: 1, remoteID: 42)))
        XCTAssertNil(try buffer.receive(.streamWritable(localID: 1, remoteID: 42)))
        XCTAssertEqual(buffer.bytes, [])
    }

    func testRejectsDataFromWrongStream() {
        var buffer = ADBShellOutputBuffer(localID: 1)

        XCTAssertThrowsError(
            try buffer.receive(.streamData(localID: 2, remoteID: 42, payload: []))
        ) { error in
            XCTAssertEqual(
                error as? ADBShellOutputBufferError,
                .mismatchedStream(expectedLocalID: 1, actualLocalID: 2)
            )
        }
    }

    func testRejectsEventsAfterClose() throws {
        var buffer = ADBShellOutputBuffer(localID: 1)
        _ = try buffer.receive(.streamClosed(localID: 1, remoteID: 42))

        XCTAssertThrowsError(
            try buffer.receive(.streamData(localID: 1, remoteID: 42, payload: []))
        ) { error in
            XCTAssertEqual(error as? ADBShellOutputBufferError, .alreadyClosed(localID: 1))
        }
    }

    func testRejectsUnboundedOutput() {
        var buffer = ADBShellOutputBuffer(localID: 1)
        let payload = [UInt8](repeating: 0, count: ADBShellOutputBuffer.maximumByteCount + 1)

        XCTAssertThrowsError(
            try buffer.receive(.streamData(localID: 1, remoteID: 42, payload: payload))
        ) { error in
            XCTAssertEqual(
                error as? ADBShellOutputBufferError,
                .outputTooLarge(maximumByteCount: ADBShellOutputBuffer.maximumByteCount)
            )
        }
        XCTAssertTrue(buffer.bytes.isEmpty)
    }
}
