#if canImport(Network)
public actor ADBTLSByteTransport: ADBByteTransport {
    private let underlying: ADBNetworkTransport
    private let tls: ADBBoringSSLTLSContext

    static func upgrade(
        underlying: ADBNetworkTransport,
        identity: ADBPairingIdentityMaterial,
        role: ADBBoringSSLTLSContext.Role = .client,
        initialEncryptedInput: [UInt8] = []
    ) async throws -> ADBTLSByteTransport {
        let transport = try ADBTLSByteTransport(
            underlying: underlying,
            tls: ADBBoringSSLTLSContext(role: role, identity: identity)
        )
        try await transport.provideInitialEncryptedInput(initialEncryptedInput)
        try await transport.completeHandshake()
        return transport
    }

    init(underlying: ADBNetworkTransport, tls: ADBBoringSSLTLSContext) {
        self.underlying = underlying
        self.tls = tls
    }

    private func provideInitialEncryptedInput(_ bytes: [UInt8]) throws {
        try tls.provideEncryptedInput(bytes)
    }

    public func send(_ bytes: [UInt8]) async throws {
        var offset = 0
        while offset < bytes.count {
            let result = try tls.writePlaintext(Array(bytes[offset...]))
            let didFlush = try await flushEncryptedOutput()
            offset += result.consumedByteCount

            switch result.operation {
            case .complete:
                guard result.consumedByteCount > 0 else {
                    throw ADBTLSByteTransportError.writeMadeNoProgress
                }
            case .wantRead:
                try await receiveEncryptedInput(orThrow: .transportClosedDuringWrite)
            case .wantWrite:
                guard didFlush else {
                    throw ADBTLSByteTransportError.writeMadeNoProgress
                }
            case .closed:
                throw ADBTLSByteTransportError.transportClosedDuringWrite
            }
        }

        _ = try await flushEncryptedOutput()
    }

    public func receive() async throws -> [UInt8]? {
        while true {
            let result = try tls.readPlaintext()
            let didFlush = try await flushEncryptedOutput()
            if !result.bytes.isEmpty {
                return result.bytes
            }

            switch result.operation {
            case .complete:
                throw ADBTLSByteTransportError.readMadeNoProgress
            case .wantRead:
                guard try await receiveEncryptedInput() else {
                    return nil
                }
            case .wantWrite:
                guard didFlush else {
                    throw ADBTLSByteTransportError.readMadeNoProgress
                }
            case .closed:
                return nil
            }
        }
    }

    private func completeHandshake() async throws {
        underlying.start()

        while true {
            let result = try tls.handshake()
            let didFlush = try await flushEncryptedOutput()

            switch result {
            case .complete:
                return
            case .wantRead:
                try await receiveEncryptedInput(orThrow: .transportClosedDuringHandshake)
            case .wantWrite:
                guard didFlush else {
                    throw ADBTLSByteTransportError.handshakeMadeNoProgress
                }
            case .closed:
                throw ADBTLSByteTransportError.transportClosedDuringHandshake
            }
        }
    }

    @discardableResult
    private func flushEncryptedOutput() async throws -> Bool {
        let bytes = try tls.encryptedOutput()
        guard !bytes.isEmpty else {
            return false
        }

        try await underlying.send(bytes)
        return true
    }

    private func receiveEncryptedInput() async throws -> Bool {
        guard let bytes = try await underlying.receive() else {
            return false
        }
        if !bytes.isEmpty {
            try tls.provideEncryptedInput(bytes)
        }
        return true
    }

    private func receiveEncryptedInput(orThrow error: ADBTLSByteTransportError) async throws {
        guard try await receiveEncryptedInput() else {
            throw error
        }
    }
}

public enum ADBTLSByteTransportError: Error, Equatable, Sendable {
    case transportClosedDuringHandshake
    case transportClosedDuringWrite
    case handshakeMadeNoProgress
    case writeMadeNoProgress
    case readMadeNoProgress
}
#endif
