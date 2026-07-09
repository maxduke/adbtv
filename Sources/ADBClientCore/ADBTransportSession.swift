public struct ADBTransportSession: Sendable {
    public private(set) var driver: ADBClientDriver
    private let transport: any ADBByteTransport

    public init(driver: ADBClientDriver = ADBClientDriver(), transport: any ADBByteTransport) {
        self.driver = driver
        self.transport = transport
    }

    public mutating func connect(systemIdentity: String = "host::") async throws -> ADBTransportSessionOutput {
        let output = try driver.startConnection(systemIdentity: systemIdentity)
        try await send(output)
        return ADBTransportSessionOutput(driverOutput: output)
    }

    public mutating func startShellCommand(_ command: ADBShellCommand) async throws -> ADBTransportSessionOutput {
        let output = try driver.startShellCommand(command)
        try await send(output)
        return ADBTransportSessionOutput(driverOutput: output)
    }

    public mutating func receiveNext() async throws -> ADBTransportSessionOutput? {
        guard let bytes = try await transport.receive() else {
            return nil
        }

        let output = try driver.receiveBytes(bytes)
        try await send(output)
        return ADBTransportSessionOutput(driverOutput: output)
    }

    private func send(_ output: ADBClientDriverOutput) async throws {
        guard !output.bytesToSend.isEmpty else {
            return
        }

        try await transport.send(output.bytesToSend)
    }
}

public struct ADBTransportSessionOutput: Equatable, Sendable {
    public var driverOutput: ADBClientDriverOutput

    public init(driverOutput: ADBClientDriverOutput) {
        self.driverOutput = driverOutput
    }
}
