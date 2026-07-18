import Foundation
import XCTest
@testable import ADBClientCore

final class ADBDeviceSessionTests: XCTestCase {
    func testConnectWaitsForDeviceConnectPacket() async throws {
        let transport = InMemoryADBByteTransport(inboundChunks: [
            try deviceConnectPacket().encoded()
        ])
        var session = ADBDeviceSession(transport: transport)

        let device = try await session.connect()
        let sentChunks = await transport.sentChunks()
        let connectPacket = try XCTUnwrap(sentChunks.first).decodedPacket()

        XCTAssertEqual(device, ADBConnectedDevice(
            protocolVersion: ADBConnectionState.defaultProtocolVersion,
            maxData: ADBConnectionState.defaultMaxData,
            banner: "device::ro.product.name=tv"
        ))
        XCTAssertEqual(connectPacket.command, .connect)
        XCTAssertEqual(connectPacket.payload, Array("host::".utf8) + [0])
        XCTAssertEqual(session.connectionPhase, .connected(
            protocolVersion: ADBConnectionState.defaultProtocolVersion,
            maxData: ADBConnectionState.defaultMaxData,
            banner: "device::ro.product.name=tv"
        ))
    }

    func testConnectRespondsToAuthTokenBeforeDeviceConnects() async throws {
        let transport = InMemoryADBByteTransport(inboundChunks: [
            try ADBPacket(
                command: .auth,
                arg0: ADBAuthenticationType.token.rawValue,
                arg1: 0,
                payload: Array(repeating: 7, count: 20)
            ).encoded(),
            try deviceConnectPacket().encoded()
        ])
        var session = ADBDeviceSession(
            authenticationIdentity: TestAuthenticationIdentity(
                signature: [1, 2, 3],
                publicKeyValue: try ADBAuthenticationPublicKey("AAAA adb@ios")
            ),
            transport: transport
        )

        let device = try await session.connect()
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try $0.decodedPacket() }

        XCTAssertEqual(device.banner, "device::ro.product.name=tv")
        XCTAssertEqual(sentPackets, [
            ADBPacket(
                command: .connect,
                arg0: ADBConnectionState.defaultProtocolVersion,
                arg1: ADBConnectionState.defaultMaxData,
                payload: Array("host::".utf8) + [0]
            ),
            ADBPacket(
                command: .auth,
                arg0: ADBAuthenticationType.signature.rawValue,
                arg1: 0,
                payload: [1, 2, 3] + Array(repeating: 7, count: 20)
            )
        ])
    }

    func testConnectThrowsWhenTransportClosesBeforeDeviceConnects() async throws {
        let transport = InMemoryADBByteTransport()
        var session = ADBDeviceSession(transport: transport)

        do {
            _ = try await session.connect()
            XCTFail("Expected connect to throw when the transport closes before receiving CNXN.")
        } catch let error as ADBDeviceSessionError {
            XCTAssertEqual(error, .transportClosedBeforeConnection)
        }
    }

    func testRunShellCommandWaitsForFinishedOutput() async throws {
        let transport = InMemoryADBByteTransport(inboundChunks: [
            try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded(),
            try ADBPacket(command: .write, arg0: 42, arg1: 1, payload: Array("Sony Bravia\n".utf8)).encoded(),
            try ADBPacket(command: .close, arg0: 42, arg1: 1).encoded()
        ])
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState())),
            transport: transport
        )

        let output = try await session.runShellCommand(try ADBShellCommand("getprop ro.product.model"))
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try $0.decodedPacket() }

        XCTAssertEqual(output.utf8String, "Sony Bravia\n")
        XCTAssertEqual(sentPackets, [
            ADBPacket(
                command: .open,
                arg0: 1,
                arg1: 0,
                payload: Array("shell:getprop ro.product.model".utf8) + [0]
            ),
            ADBPacket(command: .okay, arg0: 1, arg1: 42)
        ])
    }

    func testRunShellCommandThrowsWhenTransportClosesBeforeFinish() async throws {
        let transport = InMemoryADBByteTransport()
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState())),
            transport: transport
        )

        do {
            _ = try await session.runShellCommand(try ADBShellCommand("getprop ro.product.model"))
            XCTFail("Expected shell command to throw when the transport closes before CLSE.")
        } catch let error as ADBDeviceSessionError {
            XCTAssertEqual(
                error,
                .transportClosedBeforeShellCommandFinished(command: "getprop ro.product.model")
            )
        }
    }

    func testRunServiceCapturesCoalescedBinaryOutput() async throws {
        let payload: [UInt8] = [0, 1, 2, 255]
        let inboundChunk = try [
            ADBPacket(command: .okay, arg0: 42, arg1: 1),
            ADBPacket(command: .write, arg0: 42, arg1: 1, payload: payload),
            ADBPacket(command: .close, arg0: 42, arg1: 1)
        ].reduce(into: [UInt8]()) { bytes, packet in
            bytes.append(contentsOf: try packet.encoded())
        }
        let transport = InMemoryADBByteTransport(inboundChunks: [inboundChunk])
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState())),
            transport: transport
        )

        let output = try await session.runService(
            "exec:screencap -p",
            maximumOutputByteCount: 16
        )

        XCTAssertEqual(output.bytes, payload)
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try $0.decodedPacket() }
        XCTAssertEqual(sentPackets.first?.payload, Array("exec:screencap -p".utf8) + [0])
        XCTAssertEqual(sentPackets.last, ADBPacket(command: .okay, arg0: 1, arg1: 42))
    }

    func testRunServiceRejectsOutputOverLimit() async throws {
        let transport = InMemoryADBByteTransport(inboundChunks: [
            try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded(),
            try ADBPacket(command: .write, arg0: 42, arg1: 1, payload: [1, 2, 3, 4]).encoded()
        ])
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState())),
            transport: transport
        )

        do {
            _ = try await session.runService("exec:large-output", maximumOutputByteCount: 3)
            XCTFail("Expected oversized service output to fail.")
        } catch let error as ADBDeviceSessionError {
            XCTAssertEqual(error, .serviceOutputTooLarge(maximumByteCount: 3))
        }
    }

    func testPushFileHandlesResponseCoalescedWithFinalWriteAcknowledgement() async throws {
        let remotePath = try ADBRemotePath("/data/local/tmp/adbtv/app.apk")
        let plan = try ADBSyncPushPlan(
            remotePath: remotePath,
            modificationTime: 123,
            totalByteCount: 3
        )
        let contents: [UInt8] = [1, 2, 3]
        let encoding = try plan.encode(contents: contents)
        let syncBytes = try encoding.encodedBytes()
        let maxData: UInt32 = 12
        let syncWriteChunkCount = syncBytes.chunks(maxByteCount: Int(maxData)).count
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: syncWriteChunkCount,
            responsePayload: ADBSyncFrame(id: .okay, value: 0).encoded(),
            coalesceResponseWithFinalWriteAcknowledgement: true
        ))
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState(maxData: maxData))),
            transport: transport
        )

        let eventRecorder = SyncPushEventRecorder()
        let events = try await session.pushFile(
            contents: contents,
            plan: plan,
            eventHandler: { event in
                await eventRecorder.record(event)
            }
        )
        let streamedEvents = await eventRecorder.recordedEvents()
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try $0.decodedPacket() }
        let writePackets = sentPackets.filter { $0.command == .write }
        let transferPayload = writePackets.dropLast().flatMap { $0.payload }

        XCTAssertEqual(events, [
            .started(remotePath: remotePath, totalByteCount: 3),
            .progress(sentByteCount: 3, totalByteCount: 3),
            .finishedSending(sentByteCount: 3, totalByteCount: 3),
            .completed
        ])
        XCTAssertEqual(streamedEvents, events)
        XCTAssertEqual(sentPackets.first, ADBPacket(
            command: .open,
            arg0: 1,
            arg1: 0,
            payload: Array("sync:".utf8) + [0]
        ))
        XCTAssertEqual(transferPayload, syncBytes)
        XCTAssertEqual(writePackets.last?.payload, try ADBSyncFrame.quit().encoded())
        XCTAssertEqual(sentPackets[sentPackets.count - 3], ADBPacket(command: .okay, arg0: 1, arg1: 42))
        XCTAssertEqual(sentPackets.last, ADBPacket(command: .close, arg0: 1, arg1: 42))
    }

    func testPushFileReturnsFailedEventFromSyncFailResponse() async throws {
        let remotePath = try ADBRemotePath("/data/local/tmp/adbtv/app.apk")
        let plan = try ADBSyncPushPlan(remotePath: remotePath, totalByteCount: 0)
        let encoding = try plan.encode(contents: [])
        let maxData: UInt32 = 16
        let failMessage = Array("permission denied".utf8)
        let syncWriteChunkCount = try encoding.encodedBytes()
            .chunks(maxByteCount: Int(maxData)).count
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: syncWriteChunkCount,
            responsePayload: ADBSyncFrame(id: .fail, value: UInt32(failMessage.count), payload: failMessage).encoded()
        ))
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState(maxData: maxData))),
            transport: transport
        )

        let events = try await session.pushFile(contents: [], plan: plan)

        XCTAssertEqual(events.last, .failed(message: "permission denied"))
    }

    func testPushFileAcceptsRemoteCloseAfterSuccessfulSyncResponse() async throws {
        let remotePath = try ADBRemotePath("/data/local/tmp/adbtv/app.apk")
        let contents: [UInt8] = [1, 2, 3]
        let plan = try ADBSyncPushPlan(remotePath: remotePath, totalByteCount: contents.count)
        let syncWriteChunkCount = try plan.encode(contents: contents).encodedBytes()
            .chunks(maxByteCount: 1024).count
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: syncWriteChunkCount,
            responsePayload: ADBSyncFrame(id: .okay, value: 0).encoded(),
            coalesceResponseWithFinalWriteAcknowledgement: true,
            closeAfterResponse: true
        ))
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState(maxData: 1024))),
            transport: transport
        )

        let events = try await session.pushFile(contents: contents, plan: plan)
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try $0.decodedPacket() }
        let quitPayload = try ADBSyncFrame.quit().encoded()

        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(sentPackets.filter { $0.command == .write }.count, syncWriteChunkCount)
        XCTAssertFalse(sentPackets.contains { packet in
            packet.command == .write && packet.payload == quitPayload
        })
    }

    func testPushFilePacksSyncFramesUpToPeerMaxData() async throws {
        let remotePath = try ADBRemotePath("/data/local/tmp/adbtv/app.apk")
        let contents = Array(repeating: UInt8(7), count: 128 * 1024)
        let plan = try ADBSyncPushPlan(remotePath: remotePath, totalByteCount: contents.count)
        let encoding = try plan.encode(contents: contents)
        let syncBytes = try encoding.encodedBytes()
        let maxData: UInt32 = 1024 * 1024
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: 1,
            responsePayload: ADBSyncFrame(id: .okay, value: 0).encoded(),
            coalesceResponseWithFinalWriteAcknowledgement: true
        ))
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState(maxData: maxData))),
            transport: transport
        )

        _ = try await session.pushFile(contents: contents, plan: plan)
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try $0.decodedPacket() }
        let writePackets = sentPackets.filter { $0.command == .write }

        XCTAssertEqual(writePackets.count, 2, "Expected one packed transfer write plus QUIT.")
        XCTAssertEqual(writePackets[0].payload, syncBytes)
        XCTAssertEqual(writePackets[1].payload, try ADBSyncFrame.quit().encoded())
    }

    func testPushFileCapsBatchesWhenPeerAdvertisesOversizedMaxData() async throws {
        let remotePath = try ADBRemotePath("/data/local/tmp/adbtv/large.apk")
        let contents = Array(repeating: UInt8(9), count: 1280 * 1024)
        let plan = try ADBSyncPushPlan(remotePath: remotePath, totalByteCount: contents.count)
        let syncBytes = try plan.encode(contents: contents).encodedBytes()
        let maximumBatchByteCount = 1024 * 1024
        let expectedTransferWriteCount = syncBytes.chunks(
            maxByteCount: maximumBatchByteCount
        ).count
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: expectedTransferWriteCount,
            responsePayload: ADBSyncFrame(id: .okay, value: 0).encoded(),
            coalesceResponseWithFinalWriteAcknowledgement: true
        ))
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState(maxData: 2 * 1024 * 1024))),
            transport: transport
        )

        let events = try await session.pushFile(contents: contents, plan: plan)
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try $0.decodedPacket() }
        let transferWrites = sentPackets.filter { $0.command == .write }.dropLast()

        XCTAssertEqual(transferWrites.count, expectedTransferWriteCount)
        XCTAssertTrue(transferWrites.allSatisfy { $0.payload.count <= maximumBatchByteCount })
        XCTAssertEqual(transferWrites.flatMap(\.payload), syncBytes)
        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(
            events.filter { event in
                if case .progress = event { return true }
                return false
            }.count,
            contents.count / ADBSyncFrame.maxDataByteCount
        )
    }

    func testListDirectoryDecodesEntriesAndFiltersDotEntries() async throws {
        let path = ADBRemotePath.sharedStorageDirectory
        let response = syncDirectoryEntry(name: ".", mode: 0o040755)
            + syncDirectoryEntry(name: "Movies", mode: 0o040755, size: 4_096)
            + syncDirectoryEntry(name: "video.mp4", mode: 0o100644, size: 42)
            + syncDoneResponse()
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: 1,
            responsePayload: response,
            coalesceResponseWithFinalWriteAcknowledgement: true
        ))
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState(maxData: 1024))),
            transport: transport
        )

        let entries = try await session.listDirectory(path)
        let sentPackets = try await transport.sentChunks().map { try $0.decodedPacket() }
        let writePackets = sentPackets.filter { $0.command == .write }

        XCTAssertEqual(entries.map(\.name), ["Movies", "video.mp4"])
        XCTAssertEqual(entries.map(\.mode.kind), [.directory, .file])
        XCTAssertEqual(writePackets.first?.payload, try ADBSyncFrame.listV1(path: path).encoded())
        XCTAssertEqual(writePackets.last?.payload, try ADBSyncFrame.quit().encoded())
    }

    func testPullFileStreamsResponsesToDisk() async throws {
        let remotePath = try ADBRemotePath("/sdcard/Download/video.txt")
        let contents = Array("streamed file".utf8)
        let response = try ADBSyncFrame.data(contents).encoded() + syncDoneResponse()
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: 1,
            responsePayload: response,
            coalesceResponseWithFinalWriteAcknowledgement: true
        ))
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState(maxData: 1024))),
            transport: transport
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let recorder = SyncPullEventRecorder()

        let byteCount = try await session.pullFile(
            remotePath,
            to: destination,
            expectedByteCount: Int64(contents.count),
            eventHandler: { event in await recorder.record(event) }
        )

        XCTAssertEqual(byteCount, Int64(contents.count))
        XCTAssertEqual(try Data(contentsOf: destination), Data(contents))
        let recordedEvents = await recorder.recordedEvents()
        XCTAssertEqual(recordedEvents, [
            .started(remotePath: remotePath, totalByteCount: Int64(contents.count)),
            .progress(
                receivedByteCount: Int64(contents.count),
                totalByteCount: Int64(contents.count)
            ),
            .completed(receivedByteCount: Int64(contents.count))
        ])
    }

    func testPushFileStreamsLocalURLInPackedWrites() async throws {
        let remotePath = try ADBRemotePath("/sdcard/Download/video.txt")
        let contents = Array("streamed file".utf8)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data(contents).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let plan = try ADBSyncPushPlan(remotePath: remotePath, totalByteCount: contents.count)
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: 1,
            responsePayload: ADBSyncFrame(id: .okay, value: 0).encoded(),
            coalesceResponseWithFinalWriteAcknowledgement: true
        ))
        var session = ADBDeviceSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState(maxData: 1024))),
            transport: transport
        )

        let events = try await session.pushFile(from: source, plan: plan)
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try $0.decodedPacket() }
        let transferPayload = sentPackets.filter { $0.command == .write }.dropLast().flatMap(\.payload)

        XCTAssertEqual(transferPayload, try plan.encode(contents: contents).encodedBytes())
        XCTAssertEqual(events.last, .completed)
    }

    func testTransportSessionOutputExtractsConnectedDeviceAndFinishedShellOutput() throws {
        let connectedOutput = try ADBTransportSessionOutput(driverOutput: ADBClientDriverOutput(
            actions: [
                ADBClientAction(events: [
                    .connected(protocolVersion: 1, maxData: 2, banner: "device::")
                ])
            ]
        ))
        let shellOutput = ADBShellOutput(bytes: Array("ok".utf8))
        let finishedOutput = try ADBTransportSessionOutput(driverOutput: ADBClientDriverOutput(
            actions: [
                ADBClientAction(shellResults: [.finished(shellOutput)])
            ]
        ))

        XCTAssertEqual(connectedOutput.connectedDevice, ADBConnectedDevice(
            protocolVersion: 1,
            maxData: 2,
            banner: "device::"
        ))
        XCTAssertEqual(finishedOutput.finishedShellOutput, shellOutput)
    }

    private func connectedState(maxData: UInt32 = ADBConnectionState.defaultMaxData) -> ADBConnectionState {
        var state = ADBConnectionState()
        _ = try? state.receive(deviceConnectPacket(maxData: maxData))
        return state
    }

    private func deviceConnectPacket(maxData: UInt32 = ADBConnectionState.defaultMaxData) -> ADBPacket {
        ADBPacket(
            command: .connect,
            arg0: ADBConnectionState.defaultProtocolVersion,
            arg1: maxData,
            payload: Array("device::ro.product.name=tv".utf8) + [0]
        )
    }

    private func syncPushInboundChunks(
        writeChunkCount: Int,
        responsePayload: [UInt8],
        coalesceResponseWithFinalWriteAcknowledgement: Bool = false,
        closeAfterResponse: Bool = false
    ) throws -> [[UInt8]] {
        var chunks = [
            try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded()
        ]
        for writeIndex in 0..<writeChunkCount {
            var acknowledgement = try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded()
            if coalesceResponseWithFinalWriteAcknowledgement && writeIndex == writeChunkCount - 1 {
                acknowledgement.append(contentsOf: try ADBPacket(
                    command: .write,
                    arg0: 42,
                    arg1: 1,
                    payload: responsePayload
                ).encoded())
                if closeAfterResponse {
                    acknowledgement.append(contentsOf: try ADBPacket(
                        command: .close,
                        arg0: 42,
                        arg1: 1
                    ).encoded())
                }
            }
            chunks.append(acknowledgement)
        }
        if !coalesceResponseWithFinalWriteAcknowledgement {
            chunks.append(
                try ADBPacket(command: .write, arg0: 42, arg1: 1, payload: responsePayload).encoded()
            )
        }
        if !closeAfterResponse {
            chunks.append(
                try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded()
            )
        }
        return chunks
    }

    private func syncDirectoryEntry(
        name: String,
        mode: UInt32,
        size: UInt32 = 0,
        modificationTime: UInt32 = 1_700_000_000
    ) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(ADBSyncID.directoryEntryV1.rawValue)
        bytes.appendLittleEndian(mode)
        bytes.appendLittleEndian(size)
        bytes.appendLittleEndian(modificationTime)
        bytes.appendLittleEndian(UInt32(nameBytes.count))
        bytes.append(contentsOf: nameBytes)
        return bytes
    }

    private func syncDoneResponse() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(ADBSyncID.done.rawValue)
        return bytes
    }
}

private actor SyncPushEventRecorder {
    private var events: [ADBSyncPushEvent] = []

    func record(_ event: ADBSyncPushEvent) {
        events.append(event)
    }

    func recordedEvents() -> [ADBSyncPushEvent] {
        events
    }
}

private actor SyncPullEventRecorder {
    private var events: [ADBSyncPullEvent] = []

    func record(_ event: ADBSyncPullEvent) {
        events.append(event)
    }

    func recordedEvents() -> [ADBSyncPullEvent] {
        events
    }
}

private actor InMemoryADBByteTransport: ADBByteTransport {
    private var inboundChunks: [[UInt8]]
    private var outboundChunks: [[UInt8]]

    init(inboundChunks: [[UInt8]] = []) {
        self.inboundChunks = inboundChunks
        self.outboundChunks = []
    }

    func send(_ bytes: [UInt8]) async throws {
        outboundChunks.append(bytes)
    }

    func receive() async throws -> [UInt8]? {
        guard !inboundChunks.isEmpty else {
            return nil
        }

        return inboundChunks.removeFirst()
    }

    func sentChunks() -> [[UInt8]] {
        outboundChunks
    }
}

private extension Array where Element == UInt8 {
    func decodedPacket() throws -> ADBPacket {
        try ADBPacket.decodeFrame(from: self).packet
    }

    func chunks(maxByteCount: Int) -> [[UInt8]] {
        guard !isEmpty else {
            return []
        }

        var result: [[UInt8]] = []
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maxByteCount, count)
            result.append(Array(self[offset..<end]))
            offset = end
        }

        return result
    }
}
