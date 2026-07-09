import XCTest
@testable import ADBClientCore

final class ADBTransportSessionTests: XCTestCase {
    func testConnectSendsEncodedConnectPacket() async throws {
        let transport = InMemoryADBByteTransport()
        var session = ADBTransportSession(transport: transport)

        let output = try await session.connect()
        let sentChunks = await transport.sentChunks()
        let decoded = try XCTUnwrap(sentChunks.first).decodedPacket()

        XCTAssertEqual(output.driverOutput.packetsToSend.count, 1)
        XCTAssertEqual(sentChunks.count, 1)
        XCTAssertEqual(decoded.command, .connect)
        XCTAssertEqual(decoded.payload, Array("host::".utf8) + [0])
        XCTAssertEqual(session.driver.client.connection.phase, .connectSent)
    }

    func testStartShellCommandSendsEncodedOpenPacket() async throws {
        let transport = InMemoryADBByteTransport()
        var session = ADBTransportSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState())),
            transport: transport
        )

        _ = try await session.startShellCommand(try ADBShellCommand("getprop ro.product.model"))
        let sentChunks = await transport.sentChunks()
        let decoded = try XCTUnwrap(sentChunks.first).decodedPacket()

        XCTAssertEqual(sentChunks.count, 1)
        XCTAssertEqual(decoded, ADBPacket(
            command: .open,
            arg0: 1,
            arg1: 0,
            payload: Array("shell:getprop ro.product.model".utf8) + [0]
        ))
    }

    func testReceiveNextReturnsNilWhenTransportEnds() async throws {
        let transport = InMemoryADBByteTransport()
        var session = ADBTransportSession(transport: transport)

        let output = try await session.receiveNext()

        XCTAssertNil(output)
        XCTAssertEqual(await transport.sentChunks(), [])
    }

    func testReceiveNextProcessesInboundBytesAndSendsAck() async throws {
        let transport = InMemoryADBByteTransport()
        var session = ADBTransportSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState())),
            transport: transport
        )
        _ = try await session.startShellCommand(try ADBShellCommand("getprop ro.product.model"))
        await transport.enqueue(try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded())
        await transport.enqueue(
            try ADBPacket(command: .write, arg0: 42, arg1: 1, payload: Array("Sony".utf8)).encoded()
        )

        let ready = try await session.receiveNext()
        let data = try await session.receiveNext()
        let sentChunks = await transport.sentChunks()
        let ack = try sentChunks[1].decodedPacket()

        XCTAssertEqual(ready?.driverOutput.actions.first?.shellResults, [.opened(localID: 1, remoteID: 42)])
        XCTAssertEqual(data?.driverOutput.actions.first?.shellResults, [.updated])
        XCTAssertEqual(ack, ADBPacket(command: .okay, arg0: 1, arg1: 42))
    }

    func testReceiveNextBuffersPartialInboundBytesAcrossReceives() async throws {
        let packet = try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded()
        let transport = InMemoryADBByteTransport()
        var session = ADBTransportSession(
            driver: ADBClientDriver(client: ADBClient(connection: connectedState())),
            transport: transport
        )
        _ = try await session.startShellCommand(try ADBShellCommand("getprop ro.product.model"))
        await transport.enqueue(Array(packet.prefix(8)))
        await transport.enqueue(Array(packet.dropFirst(8)))

        let partial = try await session.receiveNext()
        let complete = try await session.receiveNext()

        XCTAssertEqual(partial?.driverOutput, try ADBClientDriverOutput())
        XCTAssertEqual(session.driver.bufferedByteCount, 0)
        XCTAssertEqual(complete?.driverOutput.actions.first?.shellResults, [.opened(localID: 1, remoteID: 42)])
    }

    private func connectedState() -> ADBConnectionState {
        var state = ADBConnectionState()
        _ = try? state.receive(
            ADBPacket(
                command: .connect,
                arg0: ADBConnectionState.defaultProtocolVersion,
                arg1: ADBConnectionState.defaultMaxData,
                payload: Array("device::".utf8) + [0]
            )
        )
        return state
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

    func enqueue(_ bytes: [UInt8]) {
        inboundChunks.append(bytes)
    }

    func sentChunks() -> [[UInt8]] {
        outboundChunks
    }
}

private extension Array where Element == UInt8 {
    func decodedPacket() throws -> ADBPacket {
        try ADBPacket.decodeFrame(from: self).packet
    }
}
