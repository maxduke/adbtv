public struct ADBClient: Sendable {
    public private(set) var connection: ADBConnectionState
    private var shellSessionsByLocalID: [UInt32: ADBShellCommandSession]
    private var authenticationResponder: ADBAuthenticationResponder?

    public init(
        connection: ADBConnectionState = ADBConnectionState(),
        authenticationResponder: ADBAuthenticationResponder? = nil
    ) {
        self.connection = connection
        self.shellSessionsByLocalID = [:]
        self.authenticationResponder = authenticationResponder
    }

    public mutating func makeConnectPacket(systemIdentity: String = "host::") -> ADBPacket {
        authenticationResponder?.reset()
        return connection.makeConnectPacket(systemIdentity: systemIdentity)
    }

    public mutating func startShellCommand(_ command: ADBShellCommand) throws -> ADBClientAction {
        var session = ADBShellCommandSession(command: command)
        let packet = try session.start(using: &connection)
        shellSessionsByLocalID[packet.arg0] = session
        return ADBClientAction(packetsToSend: [packet])
    }

    public mutating func receive(_ packet: ADBPacket) throws -> ADBClientAction {
        let result = try connection.receive(packet)
        var shellResults: [ADBShellCommandSessionResult] = []
        var packetsToSend = result.packetsToSend

        for event in result.events {
            if case .authenticationToken(let token) = event {
                if var authenticationResponder = authenticationResponder {
                    packetsToSend.append(try authenticationResponder.responsePacket(forToken: token))
                    self.authenticationResponder = authenticationResponder
                }
            }

            if case .connected = event {
                authenticationResponder?.reset()
            }

            if let localID = event.localStreamID, var session = shellSessionsByLocalID[localID] {
                let shellResult = try session.receive(event)
                shellResults.append(shellResult)

                if shellResult.isFinished {
                    shellSessionsByLocalID[localID] = nil
                } else {
                    shellSessionsByLocalID[localID] = session
                }
            }
        }

        return ADBClientAction(
            events: result.events,
            shellResults: shellResults,
            packetsToSend: packetsToSend
        )
    }

    public func shellSession(localID: UInt32) -> ADBShellCommandSession? {
        shellSessionsByLocalID[localID]
    }
}

public struct ADBClientAction: Equatable, Sendable {
    public var events: [ADBConnectionEvent]
    public var shellResults: [ADBShellCommandSessionResult]
    public var packetsToSend: [ADBPacket]

    public init(
        events: [ADBConnectionEvent] = [],
        shellResults: [ADBShellCommandSessionResult] = [],
        packetsToSend: [ADBPacket] = []
    ) {
        self.events = events
        self.shellResults = shellResults
        self.packetsToSend = packetsToSend
    }
}
