import XCTest
@testable import ADBClientCore

final class ADBClientDriverTests: XCTestCase {
    func testStartConnectionReturnsEncodedConnectPacket() throws {
        var driver = ADBClientDriver()

        let output = try driver.startConnection()
        let decoded = try ADBPacket.decodeFrame(from: output.bytesToSend)

        XCTAssertEqual(output.actions, [])
        XCTAssertEqual(output.packetsToSend.count, 1)
        XCTAssertEqual(decoded.packet.command, .connect)
        XCTAssertEqual(decoded.packet.payload, Array("host::".utf8) + [0])
        XCTAssertEqual(driver.client.connection.phase, .connectSent)
    }

    func testReceiveBytesBuffersPartialPacket() throws {
        var driver = ADBClientDriver(client: ADBClient(connection: connectedState()))
        let packet = ADBPacket(command: .okay, arg0: 42, arg1: 1)
        let encoded = try packet.encoded()

        let output = try driver.receiveBytes(Array(encoded.prefix(8)))

        XCTAssertEqual(output, try ADBClientDriverOutput())
        XCTAssertEqual(driver.bufferedByteCount, 8)
    }

    func testReceiveBytesReturnsEncodedAuthSignature() throws {
        var driver = ADBClientDriver(client: ADBClient(authenticationResponder: ADBAuthenticationResponder(
            identity: TestAuthenticationIdentity(
                signature: [8, 8],
                publicKeyValue: try ADBAuthenticationPublicKey("AAAA adb@ios")
            )
        )))

        let output = try driver.receiveBytes(
            try ADBPacket(
                command: .auth,
                arg0: ADBAuthenticationType.token.rawValue,
                arg1: 0,
                payload: [1, 2, 3]
            ).encoded()
        )
        let decoded = try ADBPacket.decodeFrame(from: output.bytesToSend)

        XCTAssertEqual(output.actions.first?.events, [.authenticationToken([1, 2, 3])])
        XCTAssertEqual(decoded.packet, ADBPacket(
            command: .auth,
            arg0: ADBAuthenticationType.signature.rawValue,
            arg1: 0,
            payload: [8, 8, 1, 2, 3]
        ))
    }

    func testStartShellCommandReturnsEncodedOpenPacket() throws {
        var driver = ADBClientDriver(client: ADBClient(connection: connectedState()))

        let output = try driver.startShellCommand(try ADBShellCommand("getprop ro.product.model"))
        let decoded = try ADBPacket.decodeFrame(from: output.bytesToSend)

        XCTAssertEqual(decoded.packet, ADBPacket(
            command: .open,
            arg0: 1,
            arg1: 0,
            payload: Array("shell:getprop ro.product.model".utf8) + [0]
        ))
        XCTAssertEqual(driver.client.shellSession(localID: 1)?.phase, .opening(localID: 1))
    }

    func testStartServiceReturnsEncodedOpenPacket() throws {
        var driver = ADBClientDriver(client: ADBClient(connection: connectedState()))

        let output = try driver.startService("sync:")
        let decoded = try ADBPacket.decodeFrame(from: output.bytesToSend)

        XCTAssertEqual(decoded.packet, ADBPacket(
            command: .open,
            arg0: 1,
            arg1: 0,
            payload: Array("sync:".utf8) + [0]
        ))
    }

    func testReceiveBytesProcessesPacketAndReturnsEncodedAck() throws {
        var driver = ADBClientDriver(client: ADBClient(connection: connectedState()))
        _ = try driver.startShellCommand(try ADBShellCommand("getprop ro.product.model"))
        _ = try driver.receiveBytes(try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded())

        let output = try driver.receiveBytes(
            try ADBPacket(command: .write, arg0: 42, arg1: 1, payload: Array("Sony".utf8)).encoded()
        )
        let decodedAck = try ADBPacket.decodeFrame(from: output.bytesToSend)

        XCTAssertEqual(output.actions.count, 1)
        XCTAssertEqual(output.actions[0].events, [
            .streamData(localID: 1, remoteID: 42, payload: Array("Sony".utf8))
        ])
        XCTAssertEqual(output.actions[0].shellResults, [.updated])
        XCTAssertEqual(decodedAck.packet, ADBPacket(command: .okay, arg0: 1, arg1: 42))
    }

    func testReceiveBytesProcessesMultiplePackets() throws {
        var driver = ADBClientDriver(client: ADBClient(connection: connectedState()))
        _ = try driver.startShellCommand(try ADBShellCommand("getprop ro.product.model"))

        let bytes = try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded()
            + ADBPacket(command: .write, arg0: 42, arg1: 1, payload: Array("Sony TV".utf8)).encoded()
            + ADBPacket(command: .close, arg0: 42, arg1: 1).encoded()

        let output = try driver.receiveBytes(bytes)

        XCTAssertEqual(output.actions.count, 3)
        XCTAssertEqual(output.actions[0].shellResults, [.opened(localID: 1, remoteID: 42)])
        XCTAssertEqual(output.actions[1].shellResults, [.updated])
        XCTAssertEqual(output.actions[2].shellResults, [
            .finished(ADBShellOutput(bytes: Array("Sony TV".utf8)))
        ])
        XCTAssertEqual(output.packetsToSend, [
            ADBPacket(command: .okay, arg0: 1, arg1: 42)
        ])
    }

    func testStaleCloseDoesNotInterruptNextStreamOpening() throws {
        var driver = ADBClientDriver(client: ADBClient(connection: connectedState()))
        _ = try driver.startShellCommand(try ADBShellCommand("mkdir -p /data/local/tmp/adbtv"))
        _ = try driver.receiveBytes(try ADBPacket(command: .okay, arg0: 42, arg1: 1).encoded())
        _ = try driver.receiveBytes(try ADBPacket(command: .close, arg0: 42, arg1: 1).encoded())
        _ = try driver.startService("sync:")

        let bytes = try ADBPacket(command: .close, arg0: 42, arg1: 1).encoded()
            + ADBPacket(command: .okay, arg0: 43, arg1: 2).encoded()
        let output = try driver.receiveBytes(bytes)

        XCTAssertEqual(output.actions.count, 2)
        XCTAssertEqual(output.actions[0], ADBClientAction())
        XCTAssertEqual(output.actions[1].events, [
            .streamReady(localID: 2, remoteID: 43)
        ])
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
