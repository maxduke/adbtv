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
    case volumeMute
    case power
    case mediaPrevious
    case mediaRewind
    case mediaPlayPause
    case mediaFastForward
    case mediaNext
    case mediaStop
    case enter
    case delete
    case tab

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
        case .volumeMute:
            return .volumeMute
        case .power:
            return .power
        case .mediaPrevious:
            return .mediaPrevious
        case .mediaRewind:
            return .mediaRewind
        case .mediaPlayPause:
            return .mediaPlayPause
        case .mediaFastForward:
            return .mediaFastForward
        case .mediaNext:
            return .mediaNext
        case .mediaStop:
            return .mediaStop
        case .enter:
            return .enter
        case .delete:
            return .delete
        case .tab:
            return .tab
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
    case tab = 61
    case enter = 66
    case delete = 67
    case menu = 82
    case mediaPlayPause = 85
    case mediaStop = 86
    case mediaNext = 87
    case mediaPrevious = 88
    case mediaRewind = 89
    case mediaFastForward = 90
    case volumeMute = 164
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
        let legacyComponent = ADBTVUnicodeInputHelper.legacyInputMethodComponent
        let legacyReceiver = ADBTVUnicodeInputHelper.legacyReceiverComponent
        let legacyAction = ADBTVUnicodeInputHelper.legacyCommitTextAction

        return "if pm path '\(ADBTVUnicodeInputHelper.packageName)' >/dev/null 2>&1; then "
            + "helper_component='\(component)'; helper_receiver='\(receiver)'; "
            + "helper_action='\(action)'; else "
            + "helper_component='\(legacyComponent)'; helper_receiver='\(legacyReceiver)'; "
            + "helper_action='\(legacyAction)'; fi; "
            + "previous_ime=\"$(settings get secure default_input_method)\" || exit 20; "
            + "restore_previous_ime() { "
            + "[ -z \"$previous_ime\" ] || [ \"$previous_ime\" = null ] "
            + "|| ime set \"$previous_ime\" >/dev/null; }; "
            + "trap 'restore_previous_ime >/dev/null 2>&1' EXIT; "
            + "trap 'exit 26' HUP INT TERM; "
            + "ime enable \"$helper_component\" >/dev/null || exit 21; "
            + "ime set \"$helper_component\" >/dev/null || exit 22; "
            + "attempt=0; broadcast_status=1; broadcast_output=''; "
            + "while [ \"$attempt\" -lt 8 ]; do "
            + "sleep 0.25; "
            + "broadcast_output=\"$(am broadcast --user current "
            + "--include-stopped-packages --receiver-foreground -a \"$helper_action\" "
            + "-n \"$helper_receiver\" --es text_base64 '\(encodedText)' 2>&1)\"; "
            + "broadcast_status=$?; "
            + "if [ \"$broadcast_status\" -eq 0 ] "
            + "&& printf '%s' \"$broadcast_output\" "
            + "| grep -q 'Broadcast completed: result=0'; then break; fi; "
            + "attempt=$((attempt + 1)); done; "
            + "restore_status=0; restore_previous_ime || restore_status=$?; "
            + "if [ \"$restore_status\" -eq 0 ]; then "
            + "trap - EXIT HUP INT TERM; else trap - HUP INT TERM; fi; "
            + "printf '%s\\n' \"$broadcast_output\"; "
            + "[ \"$broadcast_status\" -eq 0 ] || exit 23; "
            + "[ \"$restore_status\" -eq 0 ] || exit 24; "
            + "printf '%s' \"$broadcast_output\" "
            + "| grep -q 'Broadcast completed: result=0' || exit 25"
    }
}

public enum ADBTVUnicodeInputHelper: Sendable {
    public static let packageName = "com.maxduke.adbtv.helper.v3"
    public static let inputMethodComponent =
        "com.maxduke.adbtv.helper.v3/.ADBTVInputMethodService"
    public static let receiverComponent =
        "com.maxduke.adbtv.helper.v3/.TextCommitReceiver"
    public static let commitTextAction = "com.maxduke.adbtv.helper.v3.COMMIT_TEXT"
    public static let legacyInputMethodComponent =
        "com.maxduke.adbtv.helper.v2/.ADBTVInputMethodService"
    public static let legacyReceiverComponent =
        "com.maxduke.adbtv.helper.v2/.TextCommitReceiver"
    public static let legacyCommitTextAction = "com.maxduke.adbtv.helper.v2.COMMIT_TEXT"
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
