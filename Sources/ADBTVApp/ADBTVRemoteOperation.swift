import ADBClientCore
import Foundation

public protocol ADBTVRemoteConnection: Sendable {
    mutating func sendRemoteAction(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput
    mutating func sendRemoteText(_ text: ADBTVRemoteText) async throws -> ADBShellOutput
}

#if canImport(Network)
extension ADBDeviceConnection: ADBTVRemoteConnection {
    public mutating func sendRemoteAction(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput {
        let invocation = try action.shellInvocation()
        let output = try await runShellCommand(invocation.shellCommand)
        return try invocation.validatedOutput(from: output)
    }

    public mutating func sendRemoteText(_ text: ADBTVRemoteText) async throws -> ADBShellOutput {
        let invocation = try text.shellInvocation()
        let output = try await runShellCommand(invocation.shellCommand)
        return try invocation.validatedOutput(from: output)
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
