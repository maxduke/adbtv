public enum ADBConnectionPhase: Equatable, Sendable {
    case idle
    case connectSent
    case authorizing
    case connected(protocolVersion: UInt32, maxData: UInt32, banner: String)

    public var isConnected: Bool {
        if case .connected = self {
            return true
        }

        return false
    }

    public var maxData: UInt32? {
        if case .connected(_, let maxData, _) = self {
            return maxData
        }

        return nil
    }
}

public struct ADBConnectionReceiveResult: Equatable, Sendable {
    public var events: [ADBConnectionEvent]
    public var packetsToSend: [ADBPacket]

    public init(events: [ADBConnectionEvent] = [], packetsToSend: [ADBPacket] = []) {
        self.events = events
        self.packetsToSend = packetsToSend
    }
}

public enum ADBConnectionEvent: Equatable, Sendable {
    case authenticationToken([UInt8])
    case secureTransportRequested(version: UInt32)
    case connected(protocolVersion: UInt32, maxData: UInt32, banner: String)
    case streamReady(localID: UInt32, remoteID: UInt32)
    case streamWritable(localID: UInt32, remoteID: UInt32)
    case streamData(localID: UInt32, remoteID: UInt32, payload: [UInt8])
    case streamClosed(localID: UInt32, remoteID: UInt32)

    public var localStreamID: UInt32? {
        switch self {
        case .authenticationToken, .secureTransportRequested, .connected:
            return nil
        case .streamReady(let localID, _),
                .streamWritable(let localID, _),
                .streamData(let localID, _, _),
                .streamClosed(let localID, _):
            return localID
        }
    }
}

public struct ADBStream: Equatable, Sendable {
    public var localID: UInt32
    public var remoteID: UInt32?
    public var service: String
    public var state: ADBStreamState

    public init(localID: UInt32, remoteID: UInt32?, service: String, state: ADBStreamState) {
        self.localID = localID
        self.remoteID = remoteID
        self.service = service
        self.state = state
    }
}

public enum ADBStreamState: Equatable, Sendable {
    case awaitingOkay
    case open
}
