public struct ADBTVRemoteControl<Session: ADBShellCommandRunningSession>: Sendable {
    public private(set) var session: Session

    public init(session: Session) {
        self.session = session
    }

    @discardableResult
    public mutating func send(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput {
        try await session.runShellCommand(action.shellCommand())
    }

    public mutating func send(_ actions: [ADBTVRemoteAction]) async throws {
        for action in actions {
            _ = try await send(action)
        }
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
