public enum ADBSyncID: UInt32, Sendable {
    case listV1 = 0x5453_494c
    case sendV1 = 0x444e_4553
    case receiveV1 = 0x5643_4552
    case directoryEntryV1 = 0x544e_4544
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

    public static func listV1(path: ADBRemotePath) throws -> ADBSyncFrame {
        try pathRequest(id: .listV1, path: path)
    }

    public static func receiveV1(path: ADBRemotePath) throws -> ADBSyncFrame {
        try pathRequest(id: .receiveV1, path: path)
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

    private static func pathRequest(id: ADBSyncID, path: ADBRemotePath) throws -> ADBSyncFrame {
        let payload = Array(path.rawValue.utf8)
        guard payload.count <= maxPathPayloadByteCount else {
            throw ADBSyncFramingError.pathPayloadTooLarge(payload.count)
        }
        return ADBSyncFrame(id: id, value: UInt32(payload.count), payload: payload)
    }

    public func encoded() throws -> [UInt8] {
        switch id {
        case .sendV1, .listV1, .receiveV1:
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
        case .directoryEntryV1:
            throw ADBSyncFramingError.unexpectedRequestID(id)
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

    public var kind: ADBSyncEntryKind {
        switch rawValue & 0o170000 {
        case 0o040000:
            return .directory
        case 0o100000:
            return .file
        case 0o120000:
            return .symbolicLink
        default:
            return .other
        }
    }
}

public enum ADBSyncEntryKind: Equatable, Sendable {
    case directory
    case file
    case symbolicLink
    case other
}

public struct ADBSyncDirectoryEntry: Equatable, Sendable {
    public var name: String
    public var mode: ADBSyncFileMode
    public var byteCount: UInt32
    public var modificationTime: UInt32

    public init(
        name: String,
        mode: ADBSyncFileMode,
        byteCount: UInt32,
        modificationTime: UInt32
    ) {
        self.name = name
        self.mode = mode
        self.byteCount = byteCount
        self.modificationTime = modificationTime
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

public enum ADBSyncDirectoryResponse: Equatable, Sendable {
    case entry(ADBSyncDirectoryEntry)
    case done
    case fail(message: String)
}

public struct ADBSyncDirectoryResponseDecoder: Sendable {
    private static let entryHeaderByteCount = 20
    private static let maximumNameByteCount = ADBSyncFrame.maxPathPayloadByteCount
    private static let maximumMessageByteCount = 64 * 1024

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) throws -> [ADBSyncDirectoryResponse] {
        buffer.append(contentsOf: bytes)
        var responses: [ADBSyncDirectoryResponse] = []

        while buffer.count >= 4 {
            let rawID = buffer.readLittleEndianUInt32(at: 0)
            guard let id = ADBSyncID(rawValue: rawID) else {
                throw ADBSyncFramingError.unknownID(rawID)
            }

            switch id {
            case .directoryEntryV1:
                guard buffer.count >= Self.entryHeaderByteCount else {
                    return responses
                }
                let nameByteCount = Int(buffer.readLittleEndianUInt32(at: 16))
                guard nameByteCount <= Self.maximumNameByteCount else {
                    throw ADBSyncFramingError.directoryEntryNameTooLarge(nameByteCount)
                }
                let responseByteCount = Self.entryHeaderByteCount + nameByteCount
                guard buffer.count >= responseByteCount else {
                    return responses
                }
                let nameBytes = buffer[Self.entryHeaderByteCount ..< responseByteCount]
                guard !nameBytes.contains(0), !nameBytes.contains(47) else {
                    throw ADBSyncFramingError.invalidDirectoryEntryName
                }
                responses.append(.entry(ADBSyncDirectoryEntry(
                    name: String(decoding: nameBytes, as: UTF8.self),
                    mode: ADBSyncFileMode(rawValue: buffer.readLittleEndianUInt32(at: 4)),
                    byteCount: buffer.readLittleEndianUInt32(at: 8),
                    modificationTime: buffer.readLittleEndianUInt32(at: 12)
                )))
                buffer.removeFirst(responseByteCount)

            case .done:
                buffer.removeFirst(4)
                responses.append(.done)

            case .fail:
                guard let response = try failureResponse(maximumByteCount: Self.maximumMessageByteCount) else {
                    return responses
                }
                responses.append(response)

            default:
                throw ADBSyncFramingError.unexpectedResponseID(id)
            }
        }

        return responses
    }

    private mutating func failureResponse(
        maximumByteCount: Int
    ) throws -> ADBSyncDirectoryResponse? {
        guard buffer.count >= ADBSyncFrame.headerLength else {
            return nil
        }
        let messageByteCount = Int(buffer.readLittleEndianUInt32(at: 4))
        guard messageByteCount <= maximumByteCount else {
            throw ADBSyncFramingError.failureMessageTooLarge(messageByteCount)
        }
        let responseByteCount = ADBSyncFrame.headerLength + messageByteCount
        guard buffer.count >= responseByteCount else {
            return nil
        }
        let message = String(
            decoding: buffer[ADBSyncFrame.headerLength ..< responseByteCount],
            as: UTF8.self
        )
        buffer.removeFirst(responseByteCount)
        return .fail(message: message)
    }
}

public enum ADBSyncPullResponse: Equatable, Sendable {
    case data([UInt8])
    case done
    case fail(message: String)
}

public struct ADBSyncPullResponseDecoder: Sendable {
    private static let maximumMessageByteCount = 64 * 1024
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) throws -> [ADBSyncPullResponse] {
        buffer.append(contentsOf: bytes)
        var responses: [ADBSyncPullResponse] = []

        while buffer.count >= 4 {
            let rawID = buffer.readLittleEndianUInt32(at: 0)
            guard let id = ADBSyncID(rawValue: rawID) else {
                throw ADBSyncFramingError.unknownID(rawID)
            }

            switch id {
            case .data:
                guard buffer.count >= ADBSyncFrame.headerLength else {
                    return responses
                }
                let dataByteCount = Int(buffer.readLittleEndianUInt32(at: 4))
                guard dataByteCount <= ADBSyncFrame.maxDataByteCount else {
                    throw ADBSyncFramingError.dataPayloadTooLarge(dataByteCount)
                }
                let responseByteCount = ADBSyncFrame.headerLength + dataByteCount
                guard buffer.count >= responseByteCount else {
                    return responses
                }
                responses.append(.data(Array(buffer[ADBSyncFrame.headerLength ..< responseByteCount])))
                buffer.removeFirst(responseByteCount)

            case .done:
                buffer.removeFirst(4)
                responses.append(.done)

            case .fail:
                guard buffer.count >= ADBSyncFrame.headerLength else {
                    return responses
                }
                let messageByteCount = Int(buffer.readLittleEndianUInt32(at: 4))
                guard messageByteCount <= Self.maximumMessageByteCount else {
                    throw ADBSyncFramingError.failureMessageTooLarge(messageByteCount)
                }
                let responseByteCount = ADBSyncFrame.headerLength + messageByteCount
                guard buffer.count >= responseByteCount else {
                    return responses
                }
                let message = String(
                    decoding: buffer[ADBSyncFrame.headerLength ..< responseByteCount],
                    as: UTF8.self
                )
                responses.append(.fail(message: message))
                buffer.removeFirst(responseByteCount)

            default:
                throw ADBSyncFramingError.unexpectedResponseID(id)
            }
        }

        return responses
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

public enum ADBSyncPullEvent: Equatable, Sendable {
    case started(remotePath: ADBRemotePath, totalByteCount: Int64?)
    case progress(receivedByteCount: Int64, totalByteCount: Int64?)
    case completed(receivedByteCount: Int64)
}

public typealias ADBSyncPullEventHandler = @Sendable (ADBSyncPullEvent) async -> Void

public enum ADBSyncFramingError: Error, Equatable, Sendable {
    case pathPayloadTooLarge(Int)
    case dataPayloadTooLarge(Int)
    case payloadLengthMismatch(expected: Int, actual: Int)
    case unexpectedPayload(id: ADBSyncID)
    case unknownID(UInt32)
    case unexpectedResponseID(ADBSyncID)
    case unexpectedRequestID(ADBSyncID)
    case directoryEntryNameTooLarge(Int)
    case invalidDirectoryEntryName
    case failureMessageTooLarge(Int)
}

public enum ADBSyncPushPlanError: Error, Equatable, Sendable {
    case negativeTotalByteCount
    case totalByteCountMismatch(expected: Int, actual: Int)
}

public enum ADBSyncTransferError: Error, Equatable, Sendable {
    case remoteFailure(String)
    case localFileSizeUnavailable
    case localFileSizeMismatch(expected: Int, actual: Int)
    case couldNotCreateLocalFile
}
