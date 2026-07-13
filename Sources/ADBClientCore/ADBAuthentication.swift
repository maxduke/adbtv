public enum ADBAuthenticationType: UInt32, Equatable, Sendable {
    case token = 1
    case signature = 2
    case rsaPublicKey = 3
}

public protocol ADBAuthenticationIdentity: Sendable {
    func signature(for token: [UInt8]) throws -> [UInt8]
    func publicKey() throws -> ADBAuthenticationPublicKey
}

public struct ADBAuthenticationPublicKey: Equatable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw ADBAuthenticationPublicKeyError.emptyKey
        }

        guard !rawValue.utf8.contains(0) else {
            throw ADBAuthenticationPublicKeyError.containsNullByte
        }

        self.rawValue = rawValue
    }

    public var payload: [UInt8] {
        ADBPayload.nullTerminatedUTF8(rawValue)
    }
}

public enum ADBAuthenticationPublicKeyError: Error, Equatable, Sendable {
    case emptyKey
    case containsNullByte
}

public struct ADBAuthenticationResponder: Sendable {
    private let identity: any ADBAuthenticationIdentity
    private var hasSentSignature: Bool

    public init(identity: any ADBAuthenticationIdentity) {
        self.identity = identity
        self.hasSentSignature = false
    }

    public mutating func responsePacket(forToken token: [UInt8]) throws -> ADBPacket {
        if hasSentSignature {
            let publicKey = try identity.publicKey()
            return ADBPacket(
                command: .auth,
                arg0: ADBAuthenticationType.rsaPublicKey.rawValue,
                arg1: 0,
                payload: publicKey.payload
            )
        }

        hasSentSignature = true
        return ADBPacket(
            command: .auth,
            arg0: ADBAuthenticationType.signature.rawValue,
            arg1: 0,
            payload: try identity.signature(for: token)
        )
    }

    public mutating func reset() {
        hasSentSignature = false
    }
}
