public struct ADBPacketStreamDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) throws -> [ADBPacket] {
        buffer.append(contentsOf: bytes)

        var packets: [ADBPacket] = []

        while true {
            do {
                let decoded = try ADBPacket.decodeFrame(from: buffer)
                packets.append(decoded.packet)
                buffer.removeFirst(decoded.consumedByteCount)
            } catch let error as ADBPacketFramingError {
                switch error {
                case .incompleteHeader, .incompletePayload:
                    return packets
                default:
                    throw error
                }
            }
        }
    }

    public var bufferedByteCount: Int {
        buffer.count
    }
}
