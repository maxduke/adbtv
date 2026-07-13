public enum ADBPacketFramingError: Error, Equatable, Sendable {
    case payloadTooLarge(Int)
    case incompleteHeader(actualByteCount: Int)
    case incompletePayload(expectedByteCount: Int, actualByteCount: Int)
    case unknownCommand(UInt32)
    case invalidMagic(expected: UInt32, actual: UInt32)
    case invalidChecksum(expected: UInt32, actual: UInt32)
}
