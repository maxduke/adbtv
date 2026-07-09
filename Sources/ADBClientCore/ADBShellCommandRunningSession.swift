public protocol ADBShellCommandRunningSession: Sendable {
    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput
}

extension ADBDeviceSession: ADBShellCommandRunningSession {}
