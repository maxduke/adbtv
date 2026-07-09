import XCTest
@testable import ADBClientCore

final class ADBTVRemoteControlTests: XCTestCase {
    func testRemoteActionsUseExpectedAndroidKeyEvents() {
        XCTAssertEqual(ADBTVRemoteAction.home.keyEvent, .home)
        XCTAssertEqual(ADBTVRemoteAction.back.keyEvent, .back)
        XCTAssertEqual(ADBTVRemoteAction.up.keyEvent, .dpadUp)
        XCTAssertEqual(ADBTVRemoteAction.down.keyEvent, .dpadDown)
        XCTAssertEqual(ADBTVRemoteAction.left.keyEvent, .dpadLeft)
        XCTAssertEqual(ADBTVRemoteAction.right.keyEvent, .dpadRight)
        XCTAssertEqual(ADBTVRemoteAction.select.keyEvent, .dpadCenter)
        XCTAssertEqual(ADBTVRemoteAction.settings.keyEvent, .settings)
        XCTAssertEqual(ADBTVRemoteAction.menu.keyEvent, .menu)
        XCTAssertEqual(ADBTVRemoteAction.volumeUp.keyEvent, .volumeUp)
        XCTAssertEqual(ADBTVRemoteAction.volumeDown.keyEvent, .volumeDown)
        XCTAssertEqual(ADBTVRemoteAction.power.keyEvent, .power)
    }

    func testKeyEventBuildsNumericInputCommand() throws {
        let command = try ADBTVRemoteKeyEvent.settings.shellCommand()

        XCTAssertEqual(command.rawValue, "input keyevent 176")
        XCTAssertEqual(command.serviceName, "shell:input keyevent 176")
    }

    func testSendRemoteActionRunsShellCommandAndReturnsOutput() async throws {
        var remote = ADBTVRemoteControl(session: FakeShellCommandRunningSession(
            outputs: ["input keyevent 3": "ok\n"]
        ))

        let output = try await remote.send(.home)

        XCTAssertEqual(output.utf8String, "ok\n")
        XCTAssertEqual(remote.session.commands, ["input keyevent 3"])
    }

    func testSendRemoteActionsRunsCommandsInOrder() async throws {
        var remote = ADBTVRemoteControl(session: FakeShellCommandRunningSession())

        try await remote.send([.up, .select, .back])

        XCTAssertEqual(remote.session.commands, [
            "input keyevent 19",
            "input keyevent 23",
            "input keyevent 4"
        ])
    }
}

private struct FakeShellCommandRunningSession: ADBShellCommandRunningSession {
    var outputs: [String: String]
    private(set) var commands: [String]

    init(outputs: [String: String] = [:]) {
        self.outputs = outputs
        self.commands = []
    }

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        commands.append(command.rawValue)
        return ADBShellOutput(bytes: Array(outputs[command.rawValue, default: ""].utf8))
    }
}
