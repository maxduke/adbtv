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

    func testPushFileOpensSyncServiceWritesChunksAndReturnsCompletedEvent() async throws {
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
        let syncWriteChunkCount = try encoding.frames.reduce(into: 0) { count, frame in
            count += try frame.encoded().chunks(maxByteCount: Int(maxData)).count
        }
        let transport = InMemoryADBByteTransport(inboundChunks: try syncPushInboundChunks(
            writeChunkCount: syncWriteChunkCount,
            responsePayload: ADBSyncFrame(id: .okay, value: 0).encoded()
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
        let syncWriteChunkCount = try encoding.frames.reduce(into: 0) { count, frame in
            count += try frame.encoded().chunks(maxByteCount: Int(maxData)).count
        }
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

    private func syncPushInboundChunks(writeChunkCount: Int, responsePayload: [UInt8]) throws -> [[UInt8]] {
        var chunks = [
            try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded()
        ]
        chunks.append(contentsOf: try (0..<writeChunkCount).map { _ in
            try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded()
        })
        chunks.append(
            try ADBPacket(command: .write, arg0: 42, arg1: 1, payload: responsePayload).encoded()
        )
        chunks.append(
            try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded()
        )
        return chunks
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
