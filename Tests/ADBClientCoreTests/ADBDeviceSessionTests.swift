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

    private func deviceConnectPacket() -> ADBPacket {
        ADBPacket(
            command: .connect,
            arg0: ADBConnectionState.defaultProtocolVersion,
            arg1: ADBConnectionState.defaultMaxData,
            payload: Array("device::ro.product.name=tv".utf8) + [0]
        )
    }

    private func connectedState() -> ADBConnectionState {
        var state = ADBConnectionState()
        _ = try? state.receive(deviceConnectPacket())
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

    func sentChunks() -> [[UInt8]] {
        outboundChunks
    }
}

private extension Array where Element == UInt8 {
    func decodedPacket() throws -> ADBPacket {
        try ADBPacket.decodeFrame(from: self).packet
    }
}
