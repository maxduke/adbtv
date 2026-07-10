import ADBClientCore
import Foundation

public protocol ADBTVRemoteConnection: Sendable {
    mutating func sendRemoteAction(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput
}

#if canImport(Network)
extension ADBDeviceConnection: ADBTVRemoteConnection {
    public mutating func sendRemoteAction(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput {
        try await runShellCommand(action.shellCommand())
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
}

public enum ADBTVRemoteOperationError: Error, Equatable, Sendable {
    case missingDevice
    case unsupportedPlatform
}
