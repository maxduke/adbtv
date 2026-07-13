import XCTest
@testable import ADBClientCore

final class ADBShellCommandSessionTests: XCTestCase {
    func testStartOpensShellServiceThroughConnection() throws {
        var connection = connectedState()
        var session = ADBShellCommandSession(command: try ADBShellCommand("getprop ro.product.model"))

        let packet = try session.start(using: &connection)

        XCTAssertEqual(packet.command, .open)
        XCTAssertEqual(packet.arg0, 1)
        XCTAssertEqual(packet.arg1, 0)
        XCTAssertEqual(packet.payload, Array("shell:getprop ro.product.model".utf8) + [0])
        XCTAssertEqual(session.phase, .opening(localID: 1))
    }

    func testStartRejectsAlreadyStartedSession() throws {
        var connection = connectedState()
        var session = ADBShellCommandSession(command: try ADBShellCommand("getprop ro.product.model"))
        _ = try session.start(using: &connection)

        XCTAssertThrowsError(try session.start(using: &connection)) { error in
            XCTAssertEqual(error as? ADBShellCommandSessionError, .alreadyStarted)
        }
    }

    func testReceiveReadyMovesSessionToRunning() throws {
        var connection = connectedState()
        var session = ADBShellCommandSession(command: try ADBShellCommand("getprop ro.product.model"))
        _ = try session.start(using: &connection)

        let result = try session.receive(.streamReady(localID: 1, remoteID: 42))

        XCTAssertEqual(result, .opened(localID: 1, remoteID: 42))
        XCTAssertEqual(session.phase, .running(localID: 1, remoteID: 42))
    }

    func testRunningSessionCollectsDataAndFinishesOnClose() throws {
        var connection = connectedState()
        var session = ADBShellCommandSession(command: try ADBShellCommand("getprop ro.product.model"))
        _ = try session.start(using: &connection)
        _ = try session.receive(.streamReady(localID: 1, remoteID: 42))

        let first = try session.receive(.streamData(localID: 1, remoteID: 42, payload: Array("Sony ".utf8)))
        let second = try session.receive(.streamData(localID: 1, remoteID: 42, payload: Array("TV\n".utf8)))
        let finished = try session.receive(.streamClosed(localID: 1, remoteID: 42))

        XCTAssertEqual(first, .updated)
        XCTAssertEqual(second, .updated)
        XCTAssertEqual(finished, .finished(ADBShellOutput(bytes: Array("Sony TV\n".utf8))))
        XCTAssertEqual(session.phase, .finished(ADBShellOutput(bytes: Array("Sony TV\n".utf8))))
    }

    func testReceiveBeforeStartIsRejected() throws {
        var session = ADBShellCommandSession(command: try ADBShellCommand("getprop ro.product.model"))

        XCTAssertThrowsError(try session.receive(.streamReady(localID: 1, remoteID: 42))) { error in
            XCTAssertEqual(error as? ADBShellCommandSessionError, .notStarted)
        }
    }

    func testOpeningSessionRejectsWrongStreamReady() throws {
        var connection = connectedState()
        var session = ADBShellCommandSession(command: try ADBShellCommand("getprop ro.product.model"))
        _ = try session.start(using: &connection)

        XCTAssertThrowsError(try session.receive(.streamReady(localID: 2, remoteID: 42))) { error in
            XCTAssertEqual(
                error as? ADBShellCommandSessionError,
                .mismatchedStream(expectedLocalID: 1, actualLocalID: 2)
            )
        }
    }

    func testFinishedSessionRejectsMoreEvents() throws {
        var connection = connectedState()
        var session = ADBShellCommandSession(command: try ADBShellCommand("getprop ro.product.model"))
        _ = try session.start(using: &connection)
        _ = try session.receive(.streamReady(localID: 1, remoteID: 42))
        _ = try session.receive(.streamClosed(localID: 1, remoteID: 42))

        XCTAssertThrowsError(try session.receive(.streamWritable(localID: 1, remoteID: 42))) { error in
            XCTAssertEqual(error as? ADBShellCommandSessionError, .alreadyFinished)
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
