import ADBClientCore
import Foundation

public protocol ADBTVRemoteConnection: Sendable {
    mutating func sendRemoteAction(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput
    mutating func sendRemoteText(_ text: ADBTVRemoteText) async throws -> ADBShellOutput
}

#if canImport(Network)
extension ADBDeviceConnection: ADBTVRemoteConnection {
    public mutating func sendRemoteAction(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput {
        try await runShellCommand(action.shellCommand())
    }

    public mutating func sendRemoteText(_ text: ADBTVRemoteText) async throws -> ADBShellOutput {
        try await runShellCommand(text.shellCommand())
    }
}
#endif

public struct ADBTVRemoteOperation: Sendable {
    public init() {}

    @discardableResult
    public func sendAction<Connection: ADBTVRemoteConnection>(
        _ action: ADBTVRemoteAction,
        from model: ADBTVAppModel,
        using connection: inout Connection
    ) async throws -> ADBShellOutput {
        guard model.selectedDevice != nil else {
            throw ADBTVRemoteOperationError.missingDevice
        }

        return try await connection.sendRemoteAction(action)
    }

    @discardableResult
    public func sendText<Connection: ADBTVRemoteConnection>(
        _ text: ADBTVRemoteText,
        from model: ADBTVAppModel,
        using connection: inout Connection
    ) async throws -> ADBShellOutput {
        guard model.selectedDevice != nil else {
            throw ADBTVRemoteOperationError.missingDevice
        }

        return try await connection.sendRemoteText(text)
    }
}

public enum ADBTVRemoteOperationError: Error, Equatable, Sendable {
    case missingDevice
    case unsupportedPlatform
}
