public struct ADBConnectionState: Sendable {
    public static let defaultProtocolVersion: UInt32 = 0x0100_0000
    public static let defaultMaxData: UInt32 = 4096
    public static let secureTLSVersion: UInt32 = 1

    public private(set) var phase: ADBConnectionPhase
    private var nextLocalStreamID: UInt32
    private var streamsByLocalID: [UInt32: ADBStream]

    public init() {
        self.phase = .idle
        self.nextLocalStreamID = 1
        self.streamsByLocalID = [:]
    }

    public func stream(localID: UInt32) -> ADBStream? {
        streamsByLocalID[localID]
    }

    public mutating func makeConnectPacket(systemIdentity: String = "host::") -> ADBPacket {
        phase = .connectSent
        return ADBPacket(
            command: .connect,
            arg0: Self.defaultProtocolVersion,
            arg1: Self.defaultMaxData,
            payload: ADBPayload.nullTerminatedUTF8(systemIdentity)
        )
    }

    public mutating func open(service: String) throws -> ADBPacket {
        guard phase.isConnected else {
            throw ADBConnectionStateError.notConnected
        }

        guard !service.isEmpty, !service.utf8.contains(0) else {
            throw ADBConnectionStateError.invalidServiceName(service)
        }

        let localID = reserveLocalStreamID()
        streamsByLocalID[localID] = ADBStream(
            localID: localID,
            remoteID: nil,
            service: service,
            state: .awaitingOkay
        )

        return ADBPacket(
            command: .open,
            arg0: localID,
            arg1: 0,
            payload: ADBPayload.nullTerminatedUTF8(service)
        )
    }

    public mutating func write(localID: UInt32, payload: [UInt8]) throws -> ADBPacket {
        let stream = try openStream(localID: localID)
        return ADBPacket(
            command: .write,
            arg0: stream.localID,
            arg1: stream.remoteID,
            payload: payload
        )
    }

    public mutating func close(localID: UInt32) throws -> ADBPacket {
        let stream = try openStream(localID: localID)
        streamsByLocalID[localID] = nil

        return ADBPacket(
            command: .close,
            arg0: stream.localID,
            arg1: stream.remoteID
        )
    }

    public mutating func receive(_ packet: ADBPacket) throws -> ADBConnectionReceiveResult {
        switch packet.command {
        case .connect:
            let banner = ADBPayload.stringFromNullTerminatedUTF8(packet.payload)
            phase = .connected(
                protocolVersion: packet.arg0,
                maxData: packet.arg1,
                banner: banner
            )
            return ADBConnectionReceiveResult(
                events: [
                    .connected(protocolVersion: packet.arg0, maxData: packet.arg1, banner: banner)
                ]
            )

        case .auth:
            guard packet.arg0 == ADBAuthenticationType.token.rawValue else {
                throw ADBConnectionStateError.unexpectedAuthenticationType(packet.arg0)
            }

            phase = .authorizing
            return ADBConnectionReceiveResult(
                events: [.authenticationToken(packet.payload)]
            )

        case .secureTLS:
            guard phase == .connectSent else {
                throw ADBConnectionStateError.unexpectedPacket(packet.command)
            }
            guard packet.arg0 == Self.secureTLSVersion else {
                throw ADBConnectionStateError.unsupportedSecureTLSVersion(packet.arg0)
            }
            guard packet.arg1 == 0, packet.payload.isEmpty else {
                throw ADBConnectionStateError.invalidSecureTLSRequest
            }

            return ADBConnectionReceiveResult(
                events: [.secureTransportRequested(version: packet.arg0)],
                packetsToSend: [
                    ADBPacket(
                        command: .secureTLS,
                        arg0: Self.secureTLSVersion,
                        arg1: 0
                    )
                ]
            )

        case .okay:
            let remoteID = packet.arg0
            let localID = packet.arg1
            var stream = try streamForIncomingPacket(localID: localID, remoteID: remoteID, requireOpen: false)
            let wasAwaitingOkay = stream.state == .awaitingOkay
            stream.remoteID = remoteID
            stream.state = .open
            streamsByLocalID[localID] = stream

            return ADBConnectionReceiveResult(
                events: wasAwaitingOkay
                    ? [.streamReady(localID: localID, remoteID: remoteID)]
                    : [.streamWritable(localID: localID, remoteID: remoteID)]
            )

        case .write:
            let remoteID = packet.arg0
            let localID = packet.arg1
            _ = try streamForIncomingPacket(localID: localID, remoteID: remoteID, requireOpen: true)

            return ADBConnectionReceiveResult(
                events: [.streamData(localID: localID, remoteID: remoteID, payload: packet.payload)],
                packetsToSend: [
                    ADBPacket(command: .okay, arg0: localID, arg1: remoteID)
                ]
            )

        case .close:
            let remoteID = packet.arg0
            let localID = packet.arg1
            _ = try streamForIncomingPacket(localID: localID, remoteID: remoteID, requireOpen: true)
            streamsByLocalID[localID] = nil

            return ADBConnectionReceiveResult(
                events: [.streamClosed(localID: localID, remoteID: remoteID)]
            )

        case .open:
            throw ADBConnectionStateError.unexpectedPacket(packet.command)
        }
    }

    private mutating func reserveLocalStreamID() -> UInt32 {
        let localID = nextLocalStreamID
        nextLocalStreamID &+= 1
        return localID
    }

    private func openStream(localID: UInt32) throws -> ResolvedADBStream {
        guard let stream = streamsByLocalID[localID] else {
            throw ADBConnectionStateError.unknownStream(localID: localID)
        }

        guard stream.state == .open, let remoteID = stream.remoteID else {
            throw ADBConnectionStateError.streamNotReady(localID: localID)
        }

        return ResolvedADBStream(localID: stream.localID, remoteID: remoteID)
    }

    private func streamForIncomingPacket(localID: UInt32, remoteID: UInt32, requireOpen: Bool) throws -> ADBStream {
        guard let stream = streamsByLocalID[localID] else {
            throw ADBConnectionStateError.unknownStream(localID: localID)
        }

        guard !requireOpen || stream.state == .open else {
            throw ADBConnectionStateError.streamNotReady(localID: localID)
        }

        if let expectedRemoteID = stream.remoteID, expectedRemoteID != remoteID {
            throw ADBConnectionStateError.remoteStreamMismatch(
                localID: localID,
                expectedRemoteID: expectedRemoteID,
                actualRemoteID: remoteID
            )
        }

        return stream
    }
}

private struct ResolvedADBStream: Sendable {
    var localID: UInt32
    var remoteID: UInt32
}
