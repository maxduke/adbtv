public struct ADBPacket: Equatable, Sendable {
    public static let headerLength = 24

    public var command: ADBCommand
    public var arg0: UInt32
    public var arg1: UInt32
    public var payload: [UInt8]

    public init(command: ADBCommand, arg0: UInt32, arg1: UInt32, payload: [UInt8] = []) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    public var checksum: UInt32 {
        payload.reduce(0) { partial, byte in
            partial &+ UInt32(byte)
        }
    }

    public func encoded() throws -> [UInt8] {
        guard UInt64(payload.count) <= UInt64(UInt32.max) else {
            throw ADBPacketFramingError.payloadTooLarge(payload.count)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.headerLength + payload.count)
        bytes.appendLittleEndian(command.rawValue)
        bytes.appendLittleEndian(arg0)
        bytes.appendLittleEndian(arg1)
        bytes.appendLittleEndian(UInt32(payload.count))
        bytes.appendLittleEndian(checksum)
        bytes.appendLittleEndian(command.rawValue ^ 0xffff_ffff)
        bytes.append(contentsOf: payload)
        return bytes
    }

    public static func decodeFrame(from bytes: [UInt8]) throws -> ADBDecodedFrame {
        guard bytes.count >= Self.headerLength else {
            throw ADBPacketFramingError.incompleteHeader(actualByteCount: bytes.count)
        }

        let commandValue = bytes.readLittleEndianUInt32(at: 0)
        let arg0 = bytes.readLittleEndianUInt32(at: 4)
        let arg1 = bytes.readLittleEndianUInt32(at: 8)
        let payloadLength = Int(bytes.readLittleEndianUInt32(at: 12))
        let expectedChecksum = bytes.readLittleEndianUInt32(at: 16)
        let expectedMagic = bytes.readLittleEndianUInt32(at: 20)
        let actualMagic = commandValue ^ 0xffff_ffff

        guard expectedMagic == actualMagic else {
            throw ADBPacketFramingError.invalidMagic(expected: expectedMagic, actual: actualMagic)
        }

        guard bytes.count >= Self.headerLength + payloadLength else {
            throw ADBPacketFramingError.incompletePayload(
                expectedByteCount: payloadLength,
                actualByteCount: bytes.count - Self.headerLength
            )
        }

        guard let command = ADBCommand(rawValue: commandValue) else {
            throw ADBPacketFramingError.unknownCommand(commandValue)
        }

        let payloadStart = Self.headerLength
        let payloadEnd = payloadStart + payloadLength
        let payload = Array(bytes[payloadStart..<payloadEnd])
        let packet = ADBPacket(command: command, arg0: arg0, arg1: arg1, payload: payload)

        guard packet.checksum == expectedChecksum else {
            throw ADBPacketFramingError.invalidChecksum(
                expected: expectedChecksum,
                actual: packet.checksum
            )
        }

        return ADBDecodedFrame(packet: packet, consumedByteCount: payloadEnd)
    }
}

public struct ADBDecodedFrame: Equatable, Sendable {
    public var packet: ADBPacket
    public var consumedByteCount: Int

    public init(packet: ADBPacket, consumedByteCount: Int) {
        self.packet = packet
        self.consumedByteCount = consumedByteCount
    }
}
