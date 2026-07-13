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
        XCTAssertEqual(ADBTVRemoteAction.mediaPrevious.keyEvent, .mediaPrevious)
        XCTAssertEqual(ADBTVRemoteAction.mediaRewind.keyEvent, .mediaRewind)
        XCTAssertEqual(ADBTVRemoteAction.mediaPlayPause.keyEvent, .mediaPlayPause)
        XCTAssertEqual(ADBTVRemoteAction.mediaFastForward.keyEvent, .mediaFastForward)
        XCTAssertEqual(ADBTVRemoteAction.mediaNext.keyEvent, .mediaNext)
        XCTAssertEqual(ADBTVRemoteAction.mediaStop.keyEvent, .mediaStop)
        XCTAssertEqual(ADBTVRemoteAction.enter.keyEvent, .enter)
        XCTAssertEqual(ADBTVRemoteAction.delete.keyEvent, .delete)
        XCTAssertEqual(ADBTVRemoteAction.tab.keyEvent, .tab)
    }

    func testKeyEventBuildsNumericInputCommand() throws {
        let command = try ADBTVRemoteKeyEvent.settings.shellCommand()

        XCTAssertEqual(command.rawValue, "input keyevent 176")
        XCTAssertEqual(command.serviceName, "shell:input keyevent 176")
    }

    func testSendRemoteActionRunsShellCommandAndReturnsOutput() async throws {
        let shellCommand = try ADBTVRemoteAction.home.shellInvocation().shellCommand.rawValue
        var remote = ADBTVRemoteControl(session: FakeShellCommandRunningSession(
            outputs: [shellCommand: checkedRemoteOutput("ok\n")]
        ))

        let output = try await remote.send(.home)

        XCTAssertEqual(output.utf8String, "ok\n")
        XCTAssertEqual(remote.session.commands, [shellCommand])
    }

    func testSendRemoteActionsRunsCommandsInOrder() async throws {
        var remote = ADBTVRemoteControl(session: FakeShellCommandRunningSession())

        try await remote.send([.up, .select, .back])
        let expectedCommands = [
            try ADBTVRemoteAction.up.shellInvocation().shellCommand.rawValue,
            try ADBTVRemoteAction.select.shellInvocation().shellCommand.rawValue,
            try ADBTVRemoteAction.back.shellInvocation().shellCommand.rawValue
        ]

        XCTAssertEqual(remote.session.commands, expectedCommands)
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

    func testUnicodeRemoteTextUsesBundledInputHelperProtocol() throws {
        let text = try ADBTVRemoteText("你好 Android TV")
        let command = try text.shellCommand().rawValue

        XCTAssertTrue(text.requiresUnicodeInputHelper)
        XCTAssertTrue(command.contains(ADBTVUnicodeInputHelper.inputMethodComponent))
        XCTAssertTrue(command.contains(ADBTVUnicodeInputHelper.receiverComponent))
        XCTAssertTrue(command.contains(ADBTVUnicodeInputHelper.commitTextAction))
        XCTAssertTrue(command.contains("5L2g5aW9IEFuZHJvaWQgVFY="))
        XCTAssertTrue(command.contains("settings get secure default_input_method"))
        XCTAssertTrue(command.contains("ime set \"$previous_ime\""))
        XCTAssertFalse(command.contains("input text"))
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
        let shellCommand = try ADBTVRemoteText("hello tv").shellInvocation().shellCommand.rawValue
        var remote = ADBTVRemoteControl(session: FakeShellCommandRunningSession(
            outputs: [shellCommand: checkedRemoteOutput("ok\n")]
        ))

        let output = try await remote.sendText("hello tv")

        XCTAssertEqual(output.utf8String, "ok\n")
        XCTAssertEqual(remote.session.commands, [shellCommand])
    }

    func testRemoteInvocationCapturesAndStripsSuccessfulExitStatus() throws {
        let invocation = try ADBTVRemoteAction.settings.shellInvocation()

        XCTAssertEqual(
            invocation.shellCommand.rawValue,
            "input keyevent 176; __adbtv_status=$?; "
                + "printf '\\n__ADBTV_EXIT_STATUS__=%s\\n' \"$__adbtv_status\""
        )
        XCTAssertEqual(
            try invocation.validatedOutput(from: checkedRemoteOutput("device output\n")),
            ADBShellOutput(bytes: Array("device output\n".utf8))
        )
    }

    func testRemoteInvocationRejectsDeviceCommandFailure() throws {
        let invocation = try ADBTVRemoteText("\u{4F60}\u{597D}").shellInvocation()
        let output = checkedRemoteOutput(
            "java.lang.NullPointerException: key character map rejected text\n",
            exitCode: 1
        )

        XCTAssertThrowsError(try invocation.validatedOutput(from: output)) { error in
            XCTAssertEqual(
                error as? ADBTVRemoteShellInvocationError,
                .commandFailed(
                    exitCode: 1,
                    output: "java.lang.NullPointerException: key character map rejected text\n"
                )
            )
        }
    }

    func testSendTextPropagatesCheckedDeviceFailure() async throws {
        let text = try ADBTVRemoteText("\u{4F60}\u{597D}")
        let shellCommand = try text.shellInvocation().shellCommand.rawValue
        var remote = ADBTVRemoteControl(session: FakeShellCommandRunningSession(
            outputs: [shellCommand: checkedRemoteOutput("input text failed\n", exitCode: 1)]
        ))

        do {
            _ = try await remote.sendText(text)
            XCTFail("Expected the checked remote command to fail.")
        } catch let error as ADBTVRemoteShellInvocationError {
            XCTAssertEqual(
                error,
                .commandFailed(exitCode: 1, output: "input text failed\n")
            )
        }
    }

    func testRemoteInvocationRejectsMissingAndMalformedExitStatus() throws {
        let invocation = try ADBTVRemoteAction.home.shellInvocation()

        XCTAssertThrowsError(try invocation.validatedOutput(
            from: ADBShellOutput(bytes: Array("input failed".utf8))
        )) { error in
            XCTAssertEqual(
                error as? ADBTVRemoteShellInvocationError,
                .missingExitStatus(output: "input failed")
            )
        }
        XCTAssertThrowsError(try invocation.validatedOutput(
            from: ADBShellOutput(bytes: Array("\n__ADBTV_EXIT_STATUS__=bad\n".utf8))
        )) { error in
            XCTAssertEqual(
                error as? ADBTVRemoteShellInvocationError,
                .invalidExitStatus("bad")
            )
        }
    }

    func testRemoteFailureDiagnosticOutputIsBounded() throws {
        let invocation = try ADBTVRemoteAction.home.shellInvocation()
        let oversizedOutput = String(
            repeating: "x",
            count: ADBTVRemoteShellInvocation.maximumDiagnosticByteCount + 10
        )

        XCTAssertThrowsError(try invocation.validatedOutput(
            from: checkedRemoteOutput(oversizedOutput, exitCode: 2)
        )) { error in
            guard case let ADBTVRemoteShellInvocationError.commandFailed(exitCode, output) = error else {
                return XCTFail("Expected commandFailed, got \(error).")
            }
            XCTAssertEqual(exitCode, 2)
            XCTAssertEqual(
                output,
                String(repeating: "x", count: 4 * 1024) + " [truncated]"
            )
        }
    }
}

private struct FakeShellCommandRunningSession: ADBShellCommandRunningSession {
    var outputs: [String: ADBShellOutput]
    private(set) var commands: [String]

    init(outputs: [String: ADBShellOutput] = [:]) {
        self.outputs = outputs
        self.commands = []
    }

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        commands.append(command.rawValue)
        return outputs[command.rawValue] ?? checkedRemoteOutput("")
    }
}

private func checkedRemoteOutput(
    _ commandOutput: String,
    exitCode: Int = 0
) -> ADBShellOutput {
    ADBShellOutput(bytes: Array(
        (commandOutput
            + "\n\(ADBTVRemoteShellInvocation.exitStatusMarker)\(exitCode)\n").utf8
    ))
}
