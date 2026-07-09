public struct ADBClient: Sendable {
    public private(set) var connection: ADBConnectionState
    private var shellSessionsByLocalID: [UInt32: ADBShellCommandSession]

    public init(connection: ADBConnectionState = ADBConnectionState()) {
        self.connection = connection
        self.shellSessionsByLocalID = [:]
    }

    public mutating func makeConnectPacket(systemIdentity: String = "host::") -> ADBPacket {
        connection.makeConnectPacket(systemIdentity: systemIdentity)
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

        for event in result.events {
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
            packetsToSend: result.packetsToSend
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
