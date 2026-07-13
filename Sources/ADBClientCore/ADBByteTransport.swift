public protocol ADBByteTransport: Sendable {
    func send(_ bytes: [UInt8]) async throws
    func receive() async throws -> [UInt8]?
}
