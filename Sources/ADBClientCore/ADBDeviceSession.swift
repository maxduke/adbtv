public struct ADBDeviceSession: Sendable {
    public private(set) var transportSession: ADBTransportSession

    public init(transportSession: ADBTransportSession) {
        self.transportSession = transportSession
    }

    public init(driver: ADBClientDriver = ADBClientDriver(), transport: any ADBByteTransport) {
        self.transportSession = ADBTransportSession(driver: driver, transport: transport)
    }

    public var connectionPhase: ADBConnectionPhase {
        transportSession.driver.client.connection.phase
    }

    @discardableResult
    public mutating func connect(systemIdentity: String = "host::") async throws -> ADBConnectedDevice {
        _ = try await transportSession.connect(systemIdentity: systemIdentity)

        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeConnection
            }

            if let device = output.connectedDevice {
                return device
            }
        }
    }

    public mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        _ = try await transportSession.startShellCommand(command)

        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeShellCommandFinished(command: command.rawValue)
            }

            if let shellOutput = output.finishedShellOutput {
                return shellOutput
            }
        }
    }

    public mutating func receiveNext() async throws -> ADBTransportSessionOutput? {
        try await transportSession.receiveNext()
    }
}

public struct ADBConnectedDevice: Equatable, Sendable {
    public var protocolVersion: UInt32
    public var maxData: UInt32
    public var banner: String

    public init(protocolVersion: UInt32, maxData: UInt32, banner: String) {
        self.protocolVersion = protocolVersion
        self.maxData = maxData
        self.banner = banner
    }
}

public enum ADBDeviceSessionError: Error, Equatable, Sendable {
    case transportClosedBeforeConnection
    case transportClosedBeforeShellCommandFinished(command: String)
}

public extension ADBTransportSessionOutput {
    var connectedDevice: ADBConnectedDevice? {
        for action in driverOutput.actions {
            for event in action.events {
                if case .connected(let protocolVersion, let maxData, let banner) = event {
                    return ADBConnectedDevice(
                        protocolVersion: protocolVersion,
                        maxData: maxData,
                        banner: banner
                    )
                }
            }
        }

        return nil
    }

    var finishedShellOutput: ADBShellOutput? {
        for action in driverOutput.actions {
            for shellResult in action.shellResults {
                if case .finished(let output) = shellResult {
                    return output
                }
            }
        }

        return nil
    }
}
