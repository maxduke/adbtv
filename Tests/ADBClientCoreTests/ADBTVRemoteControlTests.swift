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

    func testRemoteTextBuildsShellEscapedInputTextCommand() throws {
        let text = try ADBTVRemoteText("hello tv")
        let command = try text.shellCommand()

        XCTAssertEqual(text.inputTextArgument, "hello%stv")
        XCTAssertEqual(text.shellEscapedArgument, "'hello%stv'")
        XCTAssertEqual(command.rawValue, "input text 'hello%stv'")
        XCTAssertEqual(command.serviceName, "shell:input text 'hello%stv'")
    }

    func testRemoteTextEscapesSingleQuotesAndShellMetacharacters() throws {
        let text = try ADBTVRemoteText("O'Reilly; $HOME")
        let command = try text.shellCommand()

        XCTAssertEqual(text.inputTextArgument, "O'Reilly;%s$HOME")
        XCTAssertEqual(text.shellEscapedArgument, "'O'\\''Reilly;%s$HOME'")
        XCTAssertEqual(command.rawValue, "input text 'O'\\''Reilly;%s$HOME'")
    }

    func testRemoteTextRejectsInvalidInputs() {
        XCTAssertThrowsError(try ADBTVRemoteText("")) { error in
            XCTAssertEqual(error as? ADBTVRemoteTextError, .emptyText)
        }
        XCTAssertThrowsError(try ADBTVRemoteText("line\nbreak")) { error in
            XCTAssertEqual(error as? ADBTVRemoteTextError, .containsNewline)
        }
        XCTAssertThrowsError(try ADBTVRemoteText("already%sescaped")) { error in
            XCTAssertEqual(error as? ADBTVRemoteTextError, .containsReservedSpaceEscape)
        }
        XCTAssertThrowsError(try ADBTVRemoteText("bad\u{0}text")) { error in
            XCTAssertEqual(error as? ADBTVRemoteTextError, .containsNullByte)
        }
    }

    func testSendTextRunsInputTextCommandAndReturnsOutput() async throws {
        var remote = ADBTVRemoteControl(session: FakeShellCommandRunningSession(
            outputs: ["input text 'hello%stv'": "ok\n"]
        ))

        let output = try await remote.sendText("hello tv")

        XCTAssertEqual(output.utf8String, "ok\n")
        XCTAssertEqual(remote.session.commands, ["input text 'hello%stv'"])
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
