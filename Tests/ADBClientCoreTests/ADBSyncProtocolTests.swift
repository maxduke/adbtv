import XCTest
@testable import ADBClientCore

final class ADBSyncProtocolTests: XCTestCase {
    func testListAndReceiveRequestsEncodePath() throws {
        let path = try ADBRemotePath("/sdcard/Download")

        let list = try ADBSyncFrame.listV1(path: path).encoded()
        let receive = try ADBSyncFrame.receiveV1(path: path).encoded()

        XCTAssertEqual(Array(list[0 ..< 4]), Array("LIST".utf8))
        XCTAssertEqual(Array(receive[0 ..< 4]), Array("RECV".utf8))
        XCTAssertEqual(list.readLittleEndianUInt32(at: 4), UInt32(path.rawValue.utf8.count))
        XCTAssertEqual(Array(list.dropFirst(8)), Array(path.rawValue.utf8))
        XCTAssertEqual(Array(receive.dropFirst(8)), Array(path.rawValue.utf8))
    }

    func testSendV1FrameEncodesPathAndDecimalMode() throws {
        let path = try ADBRemotePath("/data/local/tmp/adbtv/app.apk")
        let frame = try ADBSyncFrame.sendV1(path: path)

        XCTAssertEqual(frame.id, .sendV1)
        XCTAssertEqual(frame.value, 35)
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "/data/local/tmp/adbtv/app.apk,33188")

        let encoded = try frame.encoded()
        XCTAssertEqual(Array(encoded[0..<4]), Array("SEND".utf8))
        XCTAssertEqual(Array(encoded[4..<8]), [35, 0, 0, 0])
        XCTAssertEqual(Array(encoded[8...]), frame.payload)
    }

    func testDataFrameRejectsChunksLargerThanSyncLimit() throws {
        let maxChunk = [UInt8](repeating: 0xab, count: ADBSyncFrame.maxDataByteCount)
        let frame = try ADBSyncFrame.data(maxChunk)

        XCTAssertEqual(try frame.encoded().count, ADBSyncFrame.headerLength + ADBSyncFrame.maxDataByteCount)

        XCTAssertThrowsError(try ADBSyncFrame.data(maxChunk + [0xcd])) { error in
            XCTAssertEqual(error as? ADBSyncFramingError, .dataPayloadTooLarge(ADBSyncFrame.maxDataByteCount + 1))
        }
    }

    func testDoneFrameUsesModificationTimeAsSecondWord() throws {
        let frame = ADBSyncFrame.done(modificationTime: 1_700_000_000)
        let encoded = try frame.encoded()

        XCTAssertEqual(Array(encoded[0..<4]), Array("DONE".utf8))
        XCTAssertEqual(Array(encoded[4..<8]), [0, 241, 83, 101])
        XCTAssertEqual(encoded.count, ADBSyncFrame.headerLength)
    }

    func testPushPlanChunksContentsAndReportsProgress() throws {
        let path = try ADBRemotePath("/data/local/tmp/adbtv/app.apk")
        let contents = [UInt8](repeating: 0x7f, count: ADBSyncFrame.maxDataByteCount + 3)
        let plan = try ADBSyncPushPlan(
            remotePath: path,
            modificationTime: 123,
            totalByteCount: contents.count
        )

        let encoding = try plan.encode(contents: contents)

        XCTAssertEqual(encoding.frames.count, 4)
        XCTAssertEqual(encoding.frames[0].id, .sendV1)
        XCTAssertEqual(encoding.frames[1], try ADBSyncFrame.data(Array(contents.prefix(ADBSyncFrame.maxDataByteCount))))
        XCTAssertEqual(encoding.frames[2], try ADBSyncFrame.data(Array(contents.suffix(3))))
        XCTAssertEqual(encoding.frames[3], .done(modificationTime: 123))
        XCTAssertEqual(encoding.events, [
            .started(remotePath: path, totalByteCount: contents.count),
            .progress(sentByteCount: ADBSyncFrame.maxDataByteCount, totalByteCount: contents.count),
            .progress(sentByteCount: contents.count, totalByteCount: contents.count),
            .finishedSending(sentByteCount: contents.count, totalByteCount: contents.count)
        ])
    }

    func testPushPlanRejectsMismatchedTotalByteCount() throws {
        let plan = try ADBSyncPushPlan(
            remotePath: ADBRemotePath.temporaryInstallDirectory,
            totalByteCount: 4
        )

        XCTAssertThrowsError(try plan.encode(contents: [1, 2, 3])) { error in
            XCTAssertEqual(
                error as? ADBSyncPushPlanError,
                .totalByteCountMismatch(expected: 4, actual: 3)
            )
        }
    }

    func testResponseDecoderParsesPartialOkayAndFailFrames() throws {
        let failMessage = Array("permission denied".utf8)
        let bytes = try ADBSyncFrame(id: .okay, value: 0).encoded()
            + ADBSyncFrame(id: .fail, value: UInt32(failMessage.count), payload: failMessage).encoded()
        var decoder = ADBSyncResponseDecoder()

        XCTAssertEqual(try decoder.append(Array(bytes.prefix(6))), [])
        XCTAssertEqual(decoder.bufferedByteCount, 6)

        XCTAssertEqual(try decoder.append(Array(bytes.dropFirst(6))), [
            .okay,
            .fail(message: "permission denied")
        ])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testResponseDecoderRejectsUnexpectedIDs() throws {
        var decoder = ADBSyncResponseDecoder()

        XCTAssertThrowsError(try decoder.append(try ADBSyncFrame.quit().encoded())) { error in
            XCTAssertEqual(error as? ADBSyncFramingError, .unexpectedResponseID(.quit))
        }
    }

    func testDirectoryDecoderHandlesFragmentedEntriesAndDone() throws {
        let name = Array("Movies".utf8)
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(ADBSyncID.directoryEntryV1.rawValue)
        bytes.appendLittleEndian(0o040755)
        bytes.appendLittleEndian(4_096)
        bytes.appendLittleEndian(1_700_000_000)
        bytes.appendLittleEndian(UInt32(name.count))
        bytes.append(contentsOf: name)
        bytes.appendLittleEndian(ADBSyncID.done.rawValue)
        bytes.append(contentsOf: repeatElement(0, count: 16))
        var decoder = ADBSyncDirectoryResponseDecoder()

        XCTAssertEqual(try decoder.append(Array(bytes.prefix(7))), [])
        XCTAssertEqual(try decoder.append(Array(bytes.dropFirst(7))), [
            .entry(ADBSyncDirectoryEntry(
                name: "Movies",
                mode: ADBSyncFileMode(rawValue: 0o040755),
                byteCount: 4_096,
                modificationTime: 1_700_000_000
            )),
            .done
        ])
    }

    func testDirectoryDecoderWaitsForCompleteDoneRecord() throws {
        var decoder = ADBSyncDirectoryResponseDecoder()
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(ADBSyncID.done.rawValue)
        bytes.append(contentsOf: repeatElement(0, count: 16))

        XCTAssertEqual(try decoder.append(Array(bytes.prefix(4))), [])
        XCTAssertEqual(try decoder.append(Array(bytes.dropFirst(4))), [.done])
    }

    func testDirectoryDecoderRejectsPathSeparators() throws {
        let name = Array("../private".utf8)
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(ADBSyncID.directoryEntryV1.rawValue)
        bytes.appendLittleEndian(0o100644)
        bytes.appendLittleEndian(0)
        bytes.appendLittleEndian(0)
        bytes.appendLittleEndian(UInt32(name.count))
        bytes.append(contentsOf: name)
        var decoder = ADBSyncDirectoryResponseDecoder()

        XCTAssertThrowsError(try decoder.append(bytes)) { error in
            XCTAssertEqual(error as? ADBSyncFramingError, .invalidDirectoryEntryName)
        }
    }

    func testDirectoryDecoderRejectsInvalidUTF8Names() throws {
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(ADBSyncID.directoryEntryV1.rawValue)
        bytes.appendLittleEndian(0o100644)
        bytes.appendLittleEndian(0)
        bytes.appendLittleEndian(0)
        bytes.appendLittleEndian(1)
        bytes.append(0xff)
        var decoder = ADBSyncDirectoryResponseDecoder()

        XCTAssertThrowsError(try decoder.append(bytes)) { error in
            XCTAssertEqual(error as? ADBSyncFramingError, .invalidDirectoryEntryName)
        }
    }

    func testPullDecoderHandlesFragmentedDataAndDone() throws {
        let payload = Array("video".utf8)
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(ADBSyncID.data.rawValue)
        bytes.appendLittleEndian(UInt32(payload.count))
        bytes.append(contentsOf: payload)
        bytes.appendLittleEndian(ADBSyncID.done.rawValue)
        bytes.appendLittleEndian(0)
        var decoder = ADBSyncPullResponseDecoder()

        XCTAssertEqual(try decoder.append(Array(bytes.prefix(10))), [])
        XCTAssertEqual(try decoder.append(Array(bytes.dropFirst(10))), [
            .data(payload),
            .done
        ])
    }

    func testPullDecoderRejectsOversizedDataFrame() throws {
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(ADBSyncID.data.rawValue)
        bytes.appendLittleEndian(UInt32(ADBSyncFrame.maxDataByteCount + 1))
        var decoder = ADBSyncPullResponseDecoder()

        XCTAssertThrowsError(try decoder.append(bytes)) { error in
            XCTAssertEqual(
                error as? ADBSyncFramingError,
                .dataPayloadTooLarge(ADBSyncFrame.maxDataByteCount + 1)
            )
        }
    }
}
