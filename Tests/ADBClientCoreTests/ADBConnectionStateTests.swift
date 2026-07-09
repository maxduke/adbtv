import XCTest
@testable import ADBClientCore

final class ADBConnectionStateTests: XCTestCase {
    func testMakeConnectPacketUsesDefaultHostIdentity() {
        var state = ADBConnectionState()

        let packet = state.makeConnectPacket()

        XCTAssertEqual(packet.command, .connect)
        XCTAssertEqual(packet.arg0, ADBConnectionState.defaultProtocolVersion)
        XCTAssertEqual(packet.arg1, ADBConnectionState.defaultMaxData)
        XCTAssertEqual(packet.payload, Array("host::".utf8) + [0])
        XCTAssertEqual(state.phase, .connectSent)
    }

    func testReceiveConnectMovesConnectionToConnected() throws {
        var state = ADBConnectionState()
        _ = state.makeConnectPacket()

        let result = try state.receive(
            ADBPacket(
                command: .connect,
                arg0: 0x0100_0000,
                arg1: 4096,
                payload: Array("device::ro.product.name=tv".utf8) + [0]
            )
        )

        XCTAssertEqual(
            state.phase,
            .connected(protocolVersion: 0x0100_0000, maxData: 4096, banner: "device::ro.product.name=tv")
        )
        XCTAssertEqual(
            result.events,
            [.connected(protocolVersion: 0x0100_0000, maxData: 4096, banner: "device::ro.product.name=tv")]
        )
        XCTAssertEqual(result.packetsToSend, [])
    }

    func testReceiveAuthTokenMovesConnectionToAuthorizing() throws {
        var state = ADBConnectionState()
        _ = state.makeConnectPacket()

        let result = try state.receive(
            ADBPacket(command: .auth, arg0: ADBAuthenticationType.token.rawValue, arg1: 0, payload: [1, 2, 3])
        )

        XCTAssertEqual(state.phase, .authorizing)
        XCTAssertEqual(result.events, [.authenticationToken([1, 2, 3])])
        XCTAssertEqual(result.packetsToSend, [])
    }

    func testReceiveUnexpectedAuthTypeIsRejected() throws {
        var state = ADBConnectionState()

        XCTAssertThrowsError(
            try state.receive(
                ADBPacket(
                    command: .auth,
                    arg0: ADBAuthenticationType.signature.rawValue,
                    arg1: 0,
                    payload: [1, 2, 3]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ADBConnectionStateError,
                .unexpectedAuthenticationType(ADBAuthenticationType.signature.rawValue)
            )
        }
    }

    func testOpenRequiresConnectedConnection() {
        var state = ADBConnectionState()

        XCTAssertThrowsError(try state.open(service: "shell:getprop ro.product.model")) { error in
            XCTAssertEqual(error as? ADBConnectionStateError, .notConnected)
        }
    }

    func testOpenCreatesLocalStreamAwaitingOkay() throws {
        var state = connectedState()

        let packet = try state.open(service: "shell:getprop ro.product.model")

        XCTAssertEqual(packet.command, .open)
        XCTAssertEqual(packet.arg0, 1)
        XCTAssertEqual(packet.arg1, 0)
        XCTAssertEqual(packet.payload, Array("shell:getprop ro.product.model".utf8) + [0])
        XCTAssertEqual(
            state.stream(localID: 1),
            ADBStream(localID: 1, remoteID: nil, service: "shell:getprop ro.product.model", state: .awaitingOkay)
        )
    }

    func testReceiveOkayMarksStreamReady() throws {
        var state = connectedState()
        _ = try state.open(service: "shell:getprop ro.product.model")

        let result = try state.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))

        XCTAssertEqual(result.events, [.streamReady(localID: 1, remoteID: 42)])
        XCTAssertEqual(result.packetsToSend, [])
        XCTAssertEqual(
            state.stream(localID: 1),
            ADBStream(localID: 1, remoteID: 42, service: "shell:getprop ro.product.model", state: .open)
        )
    }

    func testWriteRequiresReadyStream() throws {
        var state = connectedState()
        _ = try state.open(service: "shell:cat")

        XCTAssertThrowsError(try state.write(localID: 1, payload: Array("hello".utf8))) { error in
            XCTAssertEqual(error as? ADBConnectionStateError, .streamNotReady(localID: 1))
        }
    }

    func testWriteCreatesWritePacketForOpenStream() throws {
        var state = connectedState()
        _ = try state.open(service: "shell:cat")
        _ = try state.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))

        let packet = try state.write(localID: 1, payload: Array("hello".utf8))

        XCTAssertEqual(packet.command, .write)
        XCTAssertEqual(packet.arg0, 1)
        XCTAssertEqual(packet.arg1, 42)
        XCTAssertEqual(packet.payload, Array("hello".utf8))
    }

    func testReceiveWriteReturnsDataEventAndOkayAck() throws {
        var state = connectedState()
        _ = try state.open(service: "shell:cat")
        _ = try state.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))

        let result = try state.receive(
            ADBPacket(command: .write, arg0: 42, arg1: 1, payload: Array("model\n".utf8))
        )

        XCTAssertEqual(result.events, [
            .streamData(localID: 1, remoteID: 42, payload: Array("model\n".utf8))
        ])
        XCTAssertEqual(result.packetsToSend, [
            ADBPacket(command: .okay, arg0: 1, arg1: 42)
        ])
    }

    func testReceiveWriteBeforeOkayIsRejected() throws {
        var state = connectedState()
        _ = try state.open(service: "shell:cat")

        XCTAssertThrowsError(
            try state.receive(ADBPacket(command: .write, arg0: 42, arg1: 1, payload: []))
        ) { error in
            XCTAssertEqual(error as? ADBConnectionStateError, .streamNotReady(localID: 1))
        }
    }

    func testReceiveCloseRemovesStream() throws {
        var state = connectedState()
        _ = try state.open(service: "shell:getprop")
        _ = try state.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))

        let result = try state.receive(ADBPacket(command: .close, arg0: 42, arg1: 1))

        XCTAssertEqual(result.events, [.streamClosed(localID: 1, remoteID: 42)])
        XCTAssertNil(state.stream(localID: 1))
    }

    func testCloseCreatesClosePacketAndRemovesStream() throws {
        var state = connectedState()
        _ = try state.open(service: "shell:getprop")
        _ = try state.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))

        let packet = try state.close(localID: 1)

        XCTAssertEqual(packet, ADBPacket(command: .close, arg0: 1, arg1: 42))
        XCTAssertNil(state.stream(localID: 1))
    }

    func testIncomingPacketWithWrongRemoteIDIsRejected() throws {
        var state = connectedState()
        _ = try state.open(service: "shell:getprop")
        _ = try state.receive(ADBPacket(command: .okay, arg0: 42, arg1: 1))

        XCTAssertThrowsError(
            try state.receive(ADBPacket(command: .write, arg0: 99, arg1: 1, payload: []))
        ) { error in
            XCTAssertEqual(
                error as? ADBConnectionStateError,
                .remoteStreamMismatch(localID: 1, expectedRemoteID: 42, actualRemoteID: 99)
            )
        }
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
