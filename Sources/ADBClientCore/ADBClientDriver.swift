public struct ADBClientDriver: Sendable {
    public private(set) var client: ADBClient
    private var decoder: ADBPacketStreamDecoder

    public init(client: ADBClient = ADBClient(), decoder: ADBPacketStreamDecoder = ADBPacketStreamDecoder()) {
        self.client = client
        self.decoder = decoder
    }

    public mutating func startConnection(systemIdentity: String = "host::") throws -> ADBClientDriverOutput {
        let packet = client.makeConnectPacket(systemIdentity: systemIdentity)
        return try ADBClientDriverOutput(packetsToSend: [packet])
    }

    public mutating func startShellCommand(_ command: ADBShellCommand) throws -> ADBClientDriverOutput {
        let action = try client.startShellCommand(command)
        return try ADBClientDriverOutput(actions: [action])
    }

    public mutating func receiveBytes(_ bytes: [UInt8]) throws -> ADBClientDriverOutput {
        let packets = try decoder.append(bytes)
        var actions: [ADBClientAction] = []

        for packet in packets {
            let action = try client.receive(packet)
            actions.append(action)
        }

        return try ADBClientDriverOutput(actions: actions)
    }

    public var bufferedByteCount: Int {
        decoder.bufferedByteCount
    }
}

public struct ADBClientDriverOutput: Equatable, Sendable {
    public var actions: [ADBClientAction]
    public var packetsToSend: [ADBPacket]
    public var bytesToSend: [UInt8]

    public init(actions: [ADBClientAction] = [], packetsToSend: [ADBPacket] = []) throws {
        self.actions = actions
        self.packetsToSend = packetsToSend + actions.flatMap(\.packetsToSend)
        self.bytesToSend = try self.packetsToSend.flatMap { packet in
            try packet.encoded()
        }
    }
}
