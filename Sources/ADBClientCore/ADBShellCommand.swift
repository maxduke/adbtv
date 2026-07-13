public struct ADBShellCommand: Equatable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw ADBShellCommandError.emptyCommand
        }

        guard !rawValue.utf8.contains(0) else {
            throw ADBShellCommandError.containsNullByte
        }

        self.rawValue = rawValue
    }

    public var serviceName: String {
        "shell:\(rawValue)"
    }
}

public enum ADBShellCommandError: Error, Equatable, Sendable {
    case emptyCommand
    case containsNullByte
}
