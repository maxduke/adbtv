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

    public func shellCommand() throws -> ADBShellCommand {
        try ADBShellCommand("input text \(shellEscapedArgument)")
    }

    public func shellInvocation() throws -> ADBTVRemoteShellInvocation {
        try ADBTVRemoteShellInvocation(command: shellCommand())
    }
}

public enum ADBTVRemoteTextError: Error, Equatable, Sendable {
    case emptyText
    case containsNullByte
    case containsNewline
    case containsReservedSpaceEscape
}

public struct ADBTVRemoteShellInvocation: Equatable, Sendable {
    static let exitStatusMarker = "__ADBTV_REMOTE_EXIT_STATUS__="
    static let maximumDiagnosticByteCount = 4 * 1024

    public var shellCommand: ADBShellCommand

    public init(command: ADBShellCommand) throws {
        shellCommand = try ADBShellCommand(
            "\(command.rawValue); "
                + "__adbtv_remote_status=$?; "
                + "printf '\\n\(Self.exitStatusMarker)%s\\n' \"$__adbtv_remote_status\""
        )
    }

    public func validatedOutput(from output: ADBShellOutput) throws -> ADBShellOutput {
        let marker = Array(("\n" + Self.exitStatusMarker).utf8)
        guard let markerIndex = lastIndex(of: marker, in: output.bytes) else {
            throw ADBTVRemoteShellInvocationError.missingExitStatus(
                output: diagnosticOutput(from: output.bytes)
            )
        }

        let statusStart = markerIndex + marker.count
        let statusBytes = output.bytes[statusStart...].prefix { byte in
            byte != 10 && byte != 13
        }
        guard let exitCode = Int(String(decoding: statusBytes, as: UTF8.self)),
              (0 ... 255).contains(exitCode) else {
            throw ADBTVRemoteShellInvocationError.invalidExitStatus(
                String(decoding: statusBytes, as: UTF8.self)
            )
        }

        let commandOutput = Array(output.bytes[..<markerIndex])
        guard exitCode == 0 else {
            throw ADBTVRemoteShellInvocationError.commandFailed(
                exitCode: exitCode,
                output: diagnosticOutput(from: commandOutput)
            )
        }
        return ADBShellOutput(bytes: commandOutput)
    }

    private func lastIndex(of marker: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !marker.isEmpty, bytes.count >= marker.count else {
            return nil
        }

        for index in stride(from: bytes.count - marker.count, through: 0, by: -1) {
            if bytes[index ..< index + marker.count].elementsEqual(marker) {
                return index
            }
        }
        return nil
    }

    private func diagnosticOutput(from bytes: [UInt8]) -> String {
        let prefix = bytes.prefix(Self.maximumDiagnosticByteCount)
        let value = String(decoding: prefix, as: UTF8.self)
        return bytes.count > prefix.count ? value + " [truncated]" : value
    }
}

public enum ADBTVRemoteShellInvocationError: Error, Equatable, Sendable {
    case missingExitStatus(output: String)
    case invalidExitStatus(String)
    case commandFailed(exitCode: Int, output: String)
}
