public enum ADBConnectionStateError: Error, Equatable, Sendable {
    case notConnected
    case invalidServiceName(String)
    case unexpectedPacket(ADBCommand)
    case unexpectedAuthenticationType(UInt32)
    case unknownStream(localID: UInt32)
    case streamNotReady(localID: UInt32)
    case remoteStreamMismatch(localID: UInt32, expectedRemoteID: UInt32, actualRemoteID: UInt32)
}
