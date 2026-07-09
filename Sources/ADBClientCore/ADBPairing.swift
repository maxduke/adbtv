import Foundation

public struct ADBPairingCode: Equatable, Sendable {
    public static let requiredDigitCount = 6

    public var rawValue: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.filter { !$0.isWhitespace && $0 != "-" }

        guard normalized.count == Self.requiredDigitCount else {
            throw ADBPairingCodeError.invalidDigitCount(normalized.count)
        }

        guard normalized.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            throw ADBPairingCodeError.containsNonDigit
        }

        self.rawValue = normalized
    }
}

public enum ADBPairingCodeError: Error, Equatable, Sendable {
    case invalidDigitCount(Int)
    case containsNonDigit
}

public struct ADBPairingQRCode: Equatable, Sendable {
    public var serviceName: String
    public var password: String

    public init(serviceName: String, password: String) throws {
        guard !serviceName.isEmpty else {
            throw ADBPairingQRCodeError.missingServiceName
        }

        guard !password.isEmpty else {
            throw ADBPairingQRCodeError.missingPassword
        }

        self.serviceName = serviceName
        self.password = password
    }

    public init(payload: String) throws {
        let fields = try ADBPairingQRCodeFields(payload: payload)

        guard fields.authenticationType == "ADB" else {
            throw ADBPairingQRCodeError.unsupportedAuthenticationType(fields.authenticationType)
        }

        try self.init(serviceName: fields.serviceName, password: fields.password)
    }
}

public enum ADBPairingQRCodeError: Error, Equatable, Sendable {
    case unsupportedFormat
    case unsupportedAuthenticationType(String?)
    case missingServiceName
    case missingPassword
}

public enum ADBPairingPacketType: UInt8, Equatable, Sendable {
    case spake2Message = 0
    case peerInfo = 1
}

public struct ADBPairingPacketHeader: Equatable, Sendable {
    public static let currentVersion: UInt8 = 1
    public static let encodedByteCount = 6
    public static let maximumPayloadSize = UInt32(ADBPairingPeerInfo.encodedByteCount * 2)

    public var version: UInt8
    public var type: ADBPairingPacketType
    public var payloadSize: UInt32

    public init(
        version: UInt8 = Self.currentVersion,
        type: ADBPairingPacketType,
        payloadSize: UInt32
    ) throws {
        guard version == Self.currentVersion else {
            throw ADBPairingPacketHeaderError.unsupportedVersion(version)
        }

        guard payloadSize > 0 else {
            throw ADBPairingPacketHeaderError.emptyPayload
        }

        guard payloadSize <= Self.maximumPayloadSize else {
            throw ADBPairingPacketHeaderError.payloadTooLarge(payloadSize)
        }

        self.version = version
        self.type = type
        self.payloadSize = payloadSize
    }

    public init(encodedBytes bytes: [UInt8]) throws {
        guard bytes.count == Self.encodedByteCount else {
            throw ADBPairingPacketHeaderError.invalidByteCount(bytes.count)
        }

        guard let packetType = ADBPairingPacketType(rawValue: bytes[1]) else {
            throw ADBPairingPacketHeaderError.invalidPacketType(bytes[1])
        }

        let payloadSize = UInt32(bytes[2]) << 24
            | UInt32(bytes[3]) << 16
            | UInt32(bytes[4]) << 8
            | UInt32(bytes[5])

        try self.init(version: bytes[0], type: packetType, payloadSize: payloadSize)
    }

    public func encoded() -> [UInt8] {
        [
            version,
            type.rawValue,
            UInt8((payloadSize >> 24) & 0xFF),
            UInt8((payloadSize >> 16) & 0xFF),
            UInt8((payloadSize >> 8) & 0xFF),
            UInt8(payloadSize & 0xFF)
        ]
    }
}

public enum ADBPairingPacketHeaderError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case unsupportedVersion(UInt8)
    case invalidPacketType(UInt8)
    case emptyPayload
    case payloadTooLarge(UInt32)
}

public struct ADBPairingPacket: Equatable, Sendable {
    public var header: ADBPairingPacketHeader
    public var payload: [UInt8]

    public init(type: ADBPairingPacketType, payload: [UInt8]) throws {
        let header = try ADBPairingPacketHeader(type: type, payloadSize: UInt32(payload.count))
        try self.init(header: header, payload: payload)
    }

    public init(header: ADBPairingPacketHeader, payload: [UInt8]) throws {
        guard header.payloadSize == UInt32(payload.count) else {
            throw ADBPairingPacketError.payloadSizeMismatch(
                expected: header.payloadSize,
                actual: payload.count
            )
        }

        self.header = header
        self.payload = payload
    }

    public init(encodedBytes bytes: [UInt8]) throws {
        guard bytes.count >= ADBPairingPacketHeader.encodedByteCount else {
            throw ADBPairingPacketError.invalidByteCount(bytes.count)
        }

        let headerBytes = Array(bytes.prefix(ADBPairingPacketHeader.encodedByteCount))
        let payload = Array(bytes.dropFirst(ADBPairingPacketHeader.encodedByteCount))
        try self.init(header: ADBPairingPacketHeader(encodedBytes: headerBytes), payload: payload)
    }

    public func encoded() -> [UInt8] {
        header.encoded() + payload
    }
}

public enum ADBPairingPacketError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case payloadSizeMismatch(expected: UInt32, actual: Int)
}

public enum ADBPairingPeerInfoType: UInt8, Equatable, Sendable {
    case adbRSAPublicKey = 0
    case adbDeviceGUID = 1
}

public struct ADBPairingPeerInfo: Equatable, Sendable {
    public static let encodedByteCount = 8192
    public static let maximumDataByteCount = encodedByteCount - 1

    public var type: ADBPairingPeerInfoType
    public var data: [UInt8]

    public init(type: ADBPairingPeerInfoType, data: [UInt8]) throws {
        guard data.count <= Self.maximumDataByteCount else {
            throw ADBPairingPeerInfoError.dataTooLarge(data.count)
        }

        self.type = type
        self.data = data
    }

    public init(encodedBytes bytes: [UInt8]) throws {
        guard bytes.count == Self.encodedByteCount else {
            throw ADBPairingPeerInfoError.invalidByteCount(bytes.count)
        }

        guard let type = ADBPairingPeerInfoType(rawValue: bytes[0]) else {
            throw ADBPairingPeerInfoError.invalidPeerInfoType(bytes[0])
        }

        let data = Array(bytes.dropFirst()).trimmingTrailingZeroes()
        try self.init(type: type, data: data)
    }

    public func encoded() -> [UInt8] {
        var bytes = [type.rawValue]
        bytes.append(contentsOf: data)
        if bytes.count < Self.encodedByteCount {
            bytes.append(contentsOf: repeatElement(0, count: Self.encodedByteCount - bytes.count))
        }
        return bytes
    }
}

public enum ADBPairingPeerInfoError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case invalidPeerInfoType(UInt8)
    case dataTooLarge(Int)
}

public protocol ADBPairingKeyExchange: Sendable {
    mutating func localSPAKE2Message() throws -> [UInt8]
    mutating func initializeCipher(peerSPAKE2Message: [UInt8]) throws -> any ADBPairingCipher
}

public protocol ADBPairingCipher: Sendable {
    func encrypt(_ plaintext: [UInt8]) throws -> [UInt8]
    func decrypt(_ ciphertext: [UInt8]) throws -> [UInt8]
}

public enum ADBPairingProtocolSessionState: Equatable, Sendable {
    case ready
    case waitingForSPAKE2Message
    case waitingForPeerInfo
    case finished
}

public struct ADBPairingProtocolSession: Sendable {
    public private(set) var state: ADBPairingProtocolSessionState

    private let localPeerInfo: ADBPairingPeerInfo
    private var keyExchange: any ADBPairingKeyExchange
    private var cipher: (any ADBPairingCipher)?

    public init(localPeerInfo: ADBPairingPeerInfo, keyExchange: any ADBPairingKeyExchange) {
        self.state = .ready
        self.localPeerInfo = localPeerInfo
        self.keyExchange = keyExchange
    }

    public mutating func start() throws -> ADBPairingPacket {
        guard state == .ready else {
            throw ADBPairingProtocolSessionError.invalidState(state)
        }

        let message = try keyExchange.localSPAKE2Message()
        state = .waitingForSPAKE2Message
        return try ADBPairingPacket(type: .spake2Message, payload: message)
    }

    public mutating func handlePeerSPAKE2Packet(_ packet: ADBPairingPacket) throws -> ADBPairingPacket {
        guard state == .waitingForSPAKE2Message else {
            throw ADBPairingProtocolSessionError.invalidState(state)
        }
        guard packet.header.type == .spake2Message else {
            throw ADBPairingProtocolSessionError.unexpectedPacketType(
                expected: .spake2Message,
                actual: packet.header.type
            )
        }

        let initializedCipher = try keyExchange.initializeCipher(peerSPAKE2Message: packet.payload)
        self.cipher = initializedCipher

        let encryptedPeerInfo = try initializedCipher.encrypt(localPeerInfo.encoded())
        state = .waitingForPeerInfo
        return try ADBPairingPacket(type: .peerInfo, payload: encryptedPeerInfo)
    }

    public mutating func handlePeerInfoPacket(_ packet: ADBPairingPacket) throws -> ADBPairingPeerInfo {
        guard state == .waitingForPeerInfo else {
            throw ADBPairingProtocolSessionError.invalidState(state)
        }
        guard packet.header.type == .peerInfo else {
            throw ADBPairingProtocolSessionError.unexpectedPacketType(
                expected: .peerInfo,
                actual: packet.header.type
            )
        }
        guard let cipher else {
            throw ADBPairingProtocolSessionError.missingCipher
        }

        let decryptedPeerInfo = try cipher.decrypt(packet.payload)
        guard decryptedPeerInfo.count == ADBPairingPeerInfo.encodedByteCount else {
            throw ADBPairingProtocolSessionError.invalidDecryptedPeerInfoByteCount(decryptedPeerInfo.count)
        }

        state = .finished
        return try ADBPairingPeerInfo(encodedBytes: decryptedPeerInfo)
    }
}

public enum ADBPairingProtocolSessionError: Error, Equatable, Sendable {
    case invalidState(ADBPairingProtocolSessionState)
    case unexpectedPacketType(expected: ADBPairingPacketType, actual: ADBPairingPacketType)
    case missingCipher
    case invalidDecryptedPeerInfoByteCount(Int)
}

private struct ADBPairingQRCodeFields {
    var authenticationType: String?
    var serviceName: String
    var password: String

    init(payload: String) throws {
        guard payload.hasPrefix("WIFI:") else {
            throw ADBPairingQRCodeError.unsupportedFormat
        }

        var values: [String: String] = [:]
        for field in Self.splitEscapedFields(String(payload.dropFirst("WIFI:".count))) {
            guard !field.isEmpty, let separator = Self.firstUnescapedSeparator(in: field) else {
                continue
            }

            let key = String(field[..<separator])
            let valueStart = field.index(after: separator)
            values[key] = Self.unescape(String(field[valueStart...]))
        }

        self.authenticationType = values["T"]
        self.serviceName = values["S", default: ""]
        self.password = values["P", default: ""]
    }

    private static func splitEscapedFields(_ value: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append("\\")
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == ";" {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        if isEscaped {
            current.append("\\")
        }
        if !current.isEmpty {
            fields.append(current)
        }

        return fields
    }

    private static func firstUnescapedSeparator(in value: String) -> String.Index? {
        var isEscaped = false

        for index in value.indices {
            let character = value[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == ":" {
                return index
            }
        }

        return nil
    }

    private static func unescape(_ value: String) -> String {
        var output = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                output.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                output.append(character)
            }
        }

        if isEscaped {
            output.append("\\")
        }

        return output
    }
}

private extension Array where Element == UInt8 {
    func trimmingTrailingZeroes() -> [UInt8] {
        guard let lastNonZeroIndex = lastIndex(where: { $0 != 0 }) else {
            return []
        }

        return Array(self[...lastNonZeroIndex])
    }
}
