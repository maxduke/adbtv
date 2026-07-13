public enum ADBSyncID: UInt32, Sendable {
    case sendV1 = 0x444e_4553
    case data = 0x4154_4144
    case done = 0x454e_4f44
    case okay = 0x5941_4b4f
    case fail = 0x4c49_4146
    case quit = 0x5449_5551
}

public struct ADBSyncFrame: Equatable, Sendable {
    public static let headerLength = 8
    public static let maxDataByteCount = 64 * 1024
    public static let maxPathPayloadByteCount = 1024

    public var id: ADBSyncID
    public var value: UInt32
    public var payload: [UInt8]

    public init(id: ADBSyncID, value: UInt32, payload: [UInt8] = []) {
        self.id = id
        self.value = value
        self.payload = payload
    }

    public static func sendV1(path: ADBRemotePath, mode: ADBSyncFileMode = .regular0644) throws -> ADBSyncFrame {
        let payload = Array("\(path.rawValue),\(mode.rawValue)".utf8)
        guard payload.count <= maxPathPayloadByteCount else {
            throw ADBSyncFramingError.pathPayloadTooLarge(payload.count)
        }

        return ADBSyncFrame(id: .sendV1, value: UInt32(payload.count), payload: payload)
    }

    public static func data(_ bytes: [UInt8]) throws -> ADBSyncFrame {
        guard bytes.count <= maxDataByteCount else {
            throw ADBSyncFramingError.dataPayloadTooLarge(bytes.count)
        }

        return ADBSyncFrame(id: .data, value: UInt32(bytes.count), payload: bytes)
    }

    public static func done(modificationTime: UInt32) -> ADBSyncFrame {
        ADBSyncFrame(id: .done, value: modificationTime)
    }

    public static func quit() -> ADBSyncFrame {
        ADBSyncFrame(id: .quit, value: 0)
    }

    public func encoded() throws -> [UInt8] {
        switch id {
        case .sendV1:
            guard payload.count <= Self.maxPathPayloadByteCount else {
                throw ADBSyncFramingError.pathPayloadTooLarge(payload.count)
            }
            guard value == UInt32(payload.count) else {
                throw ADBSyncFramingError.payloadLengthMismatch(expected: Int(value), actual: payload.count)
            }
        case .data:
            guard payload.count <= Self.maxDataByteCount else {
                throw ADBSyncFramingError.dataPayloadTooLarge(payload.count)
            }
            guard value == UInt32(payload.count) else {
                throw ADBSyncFramingError.payloadLengthMismatch(expected: Int(value), actual: payload.count)
            }
        case .done, .okay, .quit:
            guard payload.isEmpty else {
                throw ADBSyncFramingError.unexpectedPayload(id: id)
            }
        case .fail:
            guard value == UInt32(payload.count) else {
                throw ADBSyncFramingError.payloadLengthMismatch(expected: Int(value), actual: payload.count)
            }
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.headerLength + payload.count)
        bytes.appendLittleEndian(id.rawValue)
        bytes.appendLittleEndian(value)
        bytes.append(contentsOf: payload)
        return bytes
    }
}

public struct ADBSyncFileMode: Equatable, Sendable {
    public static let regular0644 = ADBSyncFileMode(rawValue: 0o100644)

    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum ADBSyncResponse: Equatable, Sendable {
    case okay
    case fail(message: String)
}

public struct ADBSyncResponseDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) throws -> [ADBSyncResponse] {
        buffer.append(contentsOf: bytes)

        var responses: [ADBSyncResponse] = []

        while true {
            guard buffer.count >= ADBSyncFrame.headerLength else {
                return responses
            }

            let rawID = buffer.readLittleEndianUInt32(at: 0)
            let value = buffer.readLittleEndianUInt32(at: 4)

            guard let id = ADBSyncID(rawValue: rawID) else {
                throw ADBSyncFramingError.unknownID(rawID)
            }

            switch id {
            case .okay:
                buffer.removeFirst(ADBSyncFrame.headerLength)
                responses.append(.okay)
            case .fail:
                let messageByteCount = Int(value)
                let frameByteCount = ADBSyncFrame.headerLength + messageByteCount
                guard buffer.count >= frameByteCount else {
                    return responses
                }

                let payloadStart = ADBSyncFrame.headerLength
                let payloadEnd = payloadStart + messageByteCount
                let message = String(decoding: buffer[payloadStart..<payloadEnd], as: UTF8.self)
                buffer.removeFirst(frameByteCount)
                responses.append(.fail(message: message))
            default:
                throw ADBSyncFramingError.unexpectedResponseID(id)
            }
        }
    }

    public var bufferedByteCount: Int {
        buffer.count
    }
}

public struct ADBSyncPushPlan: Equatable, Sendable {
    public var remotePath: ADBRemotePath
    public var mode: ADBSyncFileMode
    public var modificationTime: UInt32
    public var totalByteCount: Int?

    public init(
        remotePath: ADBRemotePath,
        mode: ADBSyncFileMode = .regular0644,
        modificationTime: UInt32 = 0,
        totalByteCount: Int? = nil
    ) throws {
        guard totalByteCount.map({ $0 >= 0 }) ?? true else {
            throw ADBSyncPushPlanError.negativeTotalByteCount
        }

        self.remotePath = remotePath
        self.mode = mode
        self.modificationTime = modificationTime
        self.totalByteCount = totalByteCount
    }

    public func encode(contents: [UInt8]) throws -> ADBSyncPushEncoding {
        let expectedTotal = totalByteCount ?? contents.count
        guard expectedTotal == contents.count else {
            throw ADBSyncPushPlanError.totalByteCountMismatch(expected: expectedTotal, actual: contents.count)
        }

        var frames: [ADBSyncFrame] = [try .sendV1(path: remotePath, mode: mode)]
        var events: [ADBSyncPushEvent] = [
            .started(remotePath: remotePath, totalByteCount: expectedTotal)
        ]
        var sentByteCount = 0

        var offset = 0
        while offset < contents.count {
            let end = Swift.min(offset + ADBSyncFrame.maxDataByteCount, contents.count)
            let chunk = Array(contents[offset..<end])
            sentByteCount += chunk.count
            frames.append(try .data(chunk))
            events.append(.progress(sentByteCount: sentByteCount, totalByteCount: expectedTotal))
            offset = end
        }

        frames.append(.done(modificationTime: modificationTime))
        events.append(.finishedSending(sentByteCount: sentByteCount, totalByteCount: expectedTotal))
        return ADBSyncPushEncoding(frames: frames, events: events)
    }
}

public struct ADBSyncPushEncoding: Equatable, Sendable {
    public var frames: [ADBSyncFrame]
    public var events: [ADBSyncPushEvent]

    public init(frames: [ADBSyncFrame], events: [ADBSyncPushEvent]) {
        self.frames = frames
        self.events = events
    }

    public func encodedBytes() throws -> [UInt8] {
        try frames.reduce(into: [UInt8]()) { bytes, frame in
            bytes.append(contentsOf: try frame.encoded())
        }
    }
}

public enum ADBSyncPushEvent: Equatable, Sendable {
    case started(remotePath: ADBRemotePath, totalByteCount: Int)
    case progress(sentByteCount: Int, totalByteCount: Int)
    case finishedSending(sentByteCount: Int, totalByteCount: Int)
    case completed
    case failed(message: String)

    public static func responseEvent(_ response: ADBSyncResponse) -> ADBSyncPushEvent {
        switch response {
        case .okay:
            return .completed
        case .fail(let message):
            return .failed(message: message)
        }
    }
}

public typealias ADBSyncPushEventHandler = @Sendable (ADBSyncPushEvent) async -> Void

public enum ADBSyncFramingError: Error, Equatable, Sendable {
    case pathPayloadTooLarge(Int)
    case dataPayloadTooLarge(Int)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case unexpectedPayload(id: ADBSyncID)
    case unknownID(UInt32)
    case unexpectedResponseID(ADBSyncID)
}

public enum ADBSyncPushPlanError: Error, Equatable, Sendable {
    case negativeTotalByteCount
    case totalByteCountMismatch(expected: Int, actual: Int)
}
