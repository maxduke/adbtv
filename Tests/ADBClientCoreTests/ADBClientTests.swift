import XCTest
@testable import ADBClientCore

final class ADBClientTests: XCTestCase {
    func testMakeConnectPacketDelegatesToConnectionState() {
        var client = ADBClient()

        let packet = client.makeConnectPacket()

        XCTAssertEqual(packet.command, .connect)
        XCTAssertEqual(packet.payload, Array("host::".utf8) + [0])
        XCTAssertEqual(client.connection.phase, .connectSent)
    }

    func testStartShellCommandOpensSessionAndReturnsOpenPacket() throws {
        var client = ADBClient(connection: connectedState())

        let action = try client.startShellCommand(try ADBShellCommand("getprop ro.product.model"))

        XCTAssertEqual(action.events, [])
        XCTAssertEqual(action.shellResults, [])
        XCTAssertEqual(action.packetsToSend, [
            ADBPacket(
                command: .open,
                arg0: 1,
                arg1: 0,
                payload: Array("shell:getprop ro.product.model".utf8) + [0]
            )
        ])
        XCTAssertEqual(client.shellSession(localID: 1)?.phase, .opening(localID: 1))
    }

    func testReceiveOkayUpdatesShellSession() throws {
        var client = ADBClient(connection: connectedState())
        _ = try client.startShellCommand(try ADBShellCommand("getprop ro.product.model"))

        let action = try client.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))

        XCTAssertEqual(action.events, [.streamReady(localID: 1, remoteID: 42)])
        XCTAssertEqual(action.shellResults, [.opened(localID: 1, remoteID: 42)])
        XCTAssertEqual(action.packetsToSend, [])
        XCTAssertEqual(client.shellSession(localID: 1)?.phase, .running(localID: 1, remoteID: 42))
    }

    func testReceiveWriteAcknowledgesPacketAndUpdatesShellSession() throws {
        var client = ADBClient(connection: connectedState())
        _ = try client.startShellCommand(try ADBShellCommand("getprop ro.product.model"))
        _ = try client.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))

        let action = try client.receive(
            ADBPacket(command: .write, arg0: 42, arg1: 1, payload: Array("Sony ".utf8))
        )

        XCTAssertEqual(action.events, [
            .streamData(localID: 1, remoteID: 42, payload: Array("Sony ".utf8))
        ])
        XCTAssertEqual(action.shellResults, [.updated])
        XCTAssertEqual(action.packetsToSend, [
            ADBPacket(command: .okay, arg0: 1, arg1: 42)
        ])
    }

    func testReceiveCloseFinishesShellSessionAndRemovesIt() throws {
        var client = ADBClient(connection: connectedState())
        _ = try client.startShellCommand(try ADBShellCommand("getprop ro.product.model"))
        _ = try client.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))
        _ = try client.receive(
            ADBPacket(command: .write, arg0: 42, arg1: 1, payload: Array("Sony TV\n".utf8))
        )

        let action = try client.receive(ADBPacket(command: .close, arg0: 42, arg1: 1))

        XCTAssertEqual(action.events, [.streamClosed(localID: 1, remoteID: 42)])
        XCTAssertEqual(action.shellResults, [
            .finished(ADBShellOutput(bytes: Array("Sony TV\n".utf8)))
        ])
        XCTAssertEqual(action.packetsToSend, [])
        XCTAssertNil(client.shellSession(localID: 1))
    }

    func testIgnoresEventsWithoutShellSession() throws {
        var client = ADBClient(connection: connectedState())
        var connection = client.connection
        _ = try connection.open(service: "shell:getprop ro.product.model")
        _ = try connection.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))
        client = ADBClient(connection: connection)

        let action = try client.receive(
            ADBPacket(command: .write, arg0: 42, arg1: 1, payload: Array("ignored".utf8))
        )

        XCTAssertEqual(action.events, [
            .streamData(localID: 1, remoteID: 42, payload: Array("ignored".utf8))
        ])
        XCTAssertEqual(action.shellResults, [])
        XCTAssertEqual(action.packetsToSend, [
            ADBPacket(command: .okay, arg0: 1, arg1: 42)
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
