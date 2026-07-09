public struct ADBShellOutputBuffer: Sendable {
    public let localID: UInt32
    public private(set) var bytes: [UInt8]
    public private(set) var isClosed: Bool

    public init(localID: UInt32) {
        self.localID = localID
        self.bytes = []
        self.isClosed = false
    }

    public var utf8String: String {
        String(decoding: bytes, as: UTF8.self)
    }

    public mutating func receive(_ event: ADBConnectionEvent) throws -> ADBShellOutput? {
        guard !isClosed else {
            throw ADBShellOutputBufferError.alreadyClosed(localID: localID)
        }

        switch event {
        case .streamData(let eventLocalID, _, let payload):
            guard eventLocalID == localID else {
                throw ADBShellOutputBufferError.mismatchedStream(
                    expectedLocalID: localID,
                    actualLocalID: eventLocalID
                )
            }

            bytes.append(contentsOf: payload)
            return nil

        case .streamClosed(let eventLocalID, _):
            guard eventLocalID == localID else {
                throw ADBShellOutputBufferError.mismatchedStream(
                    expectedLocalID: localID,
                    actualLocalID: eventLocalID
                )
            }

            isClosed = true
            return ADBShellOutput(bytes: bytes)

        case .authenticationToken, .connected, .streamReady, .streamWritable:
            return nil
        }
    }
}

public struct ADBShellOutput: Equatable, Sendable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var utf8String: String {
        String(decoding: bytes, as: UTF8.self)
    }
}

public enum ADBShellOutputBufferError: Error, Equatable, Sendable {
    case mismatchedStream(expectedLocalID: UInt32, actualLocalID: UInt32)
    case alreadyClosed(localID: UInt32)
}
