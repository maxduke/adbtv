import Foundation

public struct ADBTVRemoteControl<Session: ADBShellCommandRunningSession>: Sendable {
    public private(set) var session: Session

    public init(session: Session) {
        self.session = session
    }

    @discardableResult
    public mutating func send(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput {
        try await run(action.shellInvocation())
    }

    public mutating func send(_ actions: [ADBTVRemoteAction]) async throws {
        for action in actions {
            _ = try await send(action)
        }
    }

    @discardableResult
    public mutating func sendText(_ text: ADBTVRemoteText) async throws -> ADBShellOutput {
        try await run(text.shellInvocation())
    }

    @discardableResult
    public mutating func sendText(_ text: String) async throws -> ADBShellOutput {
        try await sendText(try ADBTVRemoteText(text))
    }

    private mutating func run(
        _ invocation: ADBTVRemoteShellInvocation
    ) async throws -> ADBShellOutput {
        let output = try await session.runShellCommand(invocation.shellCommand)
        return try invocation.validatedOutput(from: output)
    }
}

public enum ADBTVRemoteAction: CaseIterable, Equatable, Sendable {
    case home
    case back
    case up
    case down
    case left
    case right
    case select
    case settings
    case menu
    case volumeUp
    case volumeDown
    case power

    public var keyEvent: ADBTVRemoteKeyEvent {
        switch self {
        case .home:
            return .home
        case .back:
            return .back
        case .up:
            return .dpadUp
        case .down:
            return .dpadDown
        case .left:
            return .dpadLeft
        case .right:
            return .dpadRight
        case .select:
            return .dpadCenter
        case .settings:
            return .settings
        case .menu:
            return .menu
        case .volumeUp:
            return .volumeUp
        case .volumeDown:
            return .volumeDown
        case .power:
            return .power
        }
    }

    public func shellCommand() throws -> ADBShellCommand {
        try keyEvent.shellCommand()
    }

    public func shellInvocation() throws -> ADBTVRemoteShellInvocation {
        try ADBTVRemoteShellInvocation(command: shellCommand())
    }
}

public enum ADBTVRemoteKeyEvent: Int, Equatable, Sendable {
    case home = 3
    case back = 4
    case dpadUp = 19
    case dpadDown = 20
    case dpadLeft = 21
    case dpadRight = 22
    case dpadCenter = 23
    case volumeUp = 24
    case volumeDown = 25
    case power = 26
    case menu = 82
    case settings = 176

    public func shellCommand() throws -> ADBShellCommand {
        try ADBShellCommand("input keyevent \(rawValue)")
    }
}

public struct ADBTVRemoteText: Equatable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw ADBTVRemoteTextError.emptyText
        }

        guard !rawValue.utf8.contains(0) else {
            throw ADBTVRemoteTextError.containsNullByte
        }

        guard !rawValue.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw ADBTVRemoteTextError.containsNewline
        }

        guard !rawValue.contains("%s") else {
            throw ADBTVRemoteTextError.containsReservedSpaceEscape
        }

        self.rawValue = rawValue
    }

    public var inputTextArgument: String {
        rawValue.replacingOccurrences(of: " ", with: "%s")
    }

    public var shellEscapedArgument: String {
        "'\(inputTextArgument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public var requiresUnicodeInputHelper: Bool {
        rawValue.unicodeScalars.contains { !$0.isASCII }
    }

    public func shellCommand() throws -> ADBShellCommand {
        if requiresUnicodeInputHelper {
            return try ADBShellCommand(unicodeInputHelperCommand)
        }
        return try ADBShellCommand("input text \(shellEscapedArgument)")
    }

    public func shellInvocation() throws -> ADBTVRemoteShellInvocation {
        try ADBTVRemoteShellInvocation(command: shellCommand())
    }

    private var unicodeInputHelperCommand: String {
        let encodedText = Data(rawValue.utf8).base64EncodedString()
        let component = ADBTVUnicodeInputHelper.inputMethodComponent
        let receiver = ADBTVUnicodeInputHelper.receiverComponent
        let action = ADBTVUnicodeInputHelper.commitTextAction

        return "previous_ime=\"$(settings get secure default_input_method)\" || exit 20; "
            + "ime enable '\(component)' >/dev/null || exit 21; "
            + "ime set '\(component)' >/dev/null || exit 22; "
            + "sleep 1; "
            + "broadcast_output=\"$(am broadcast --user current -a '\(action)' "
            + "-n '\(receiver)' --es text_base64 '\(encodedText)' 2>&1)\"; "
            + "broadcast_status=$?; restore_status=0; "
            + "if [ -n \"$previous_ime\" ] && [ \"$previous_ime\" != null ]; then "
            + "ime set \"$previous_ime\" >/dev/null || restore_status=$?; fi; "
            + "printf '%s\\n' \"$broadcast_output\"; "
            + "[ \"$broadcast_status\" -eq 0 ] || exit 23; "
            + "[ \"$restore_status\" -eq 0 ] || exit 24; "
            + "printf '%s' \"$broadcast_output\" "
            + "| grep -q 'Broadcast completed: result=0' || exit 25"
    }
}

public enum ADBTVUnicodeInputHelper: Sendable {
    public static let packageName = "com.maxduke.adbtv.input"
    public static let inputMethodComponent =
        "com.maxduke.adbtv.input/.ADBTVInputMethodService"
    public static let receiverComponent =
        "com.maxduke.adbtv.input/.TextCommitReceiver"
    public static let commitTextAction = "com.maxduke.adbtv.input.COMMIT_TEXT"
    public static let bundledAPKFileName = "ADBTVInput.apk"
}

public enum ADBTVRemoteTextError: Error, Equatable, Sendable {
    case emptyText
    case containsNullByte
    case containsNewline
    case containsReservedSpaceEscape
}

public typealias ADBTVRemoteShellInvocation = ADBCheckedShellInvocation
public typealias ADBTVRemoteShellInvocationError = ADBCheckedShellInvocationError
