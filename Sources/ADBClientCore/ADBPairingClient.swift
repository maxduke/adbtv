public struct ADBPairingClient: Sendable {
    private let transport: any ADBByteTransport
    private var session: ADBPairingProtocolSession
    private var bufferedBytes: [UInt8]

    public init(session: ADBPairingProtocolSession, transport: any ADBByteTransport) {
        self.transport = transport
        self.session = session
        self.bufferedBytes = []
    }

    public mutating func pair() async throws -> ADBPairingPeerInfo {
        let localSPAKE2Packet = try session.start()
        try await transport.send(localSPAKE2Packet.encoded())

        let remoteSPAKE2Packet = try await receivePacket()
        let localPeerInfoPacket = try session.handlePeerSPAKE2Packet(remoteSPAKE2Packet)
        try await transport.send(localPeerInfoPacket.encoded())

        let remotePeerInfoPacket = try await receivePacket()
        return try session.handlePeerInfoPacket(remotePeerInfoPacket)
    }

    private mutating func receivePacket() async throws -> ADBPairingPacket {
        let headerBytes = try await receiveExactByteCount(ADBPairingPacketHeader.encodedByteCount)
        let header = try ADBPairingPacketHeader(encodedBytes: headerBytes)
        let payload = try await receiveExactByteCount(Int(header.payloadSize))
        return try ADBPairingPacket(header: header, payload: payload)
    }

    private mutating func receiveExactByteCount(_ byteCount: Int) async throws -> [UInt8] {
        while bufferedBytes.count < byteCount {
            guard let bytes = try await transport.receive() else {
                throw ADBPairingClientError.transportClosed(
                    expectedByteCount: byteCount,
                    bufferedByteCount: bufferedBytes.count
                )
            }

            bufferedBytes.append(contentsOf: bytes)
        }

        let result = Array(bufferedBytes.prefix(byteCount))
        bufferedBytes.removeFirst(byteCount)
        return result
    }
}

public enum ADBPairingClientError: Error, Equatable, Sendable {
    case transportClosed(expectedByteCount: Int, bufferedByteCount: Int)
}
