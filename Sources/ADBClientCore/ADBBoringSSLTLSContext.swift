import CADBPairingCrypto
import Foundation

final class ADBBoringSSLTLSContext: @unchecked Sendable {
    enum Role {
        case client
        case server
    }

    private var context: OpaquePointer?

    init(role: Role, identity: ADBPairingIdentityMaterial) throws {
        let createdContext = identity.certificatePEM.withUnsafeBytes { certificateBuffer in
            identity.privateKeyPEM.withUnsafeBytes { privateKeyBuffer in
                adb_tls_create(
                    role == .client ? ADB_TLS_ROLE_CLIENT : ADB_TLS_ROLE_SERVER,
                    certificateBuffer.bindMemory(to: UInt8.self).baseAddress,
                    identity.certificatePEM.count,
                    privateKeyBuffer.bindMemory(to: UInt8.self).baseAddress,
                    identity.privateKeyPEM.count
                )
            }
        }
        guard let createdContext else {
            throw ADBTLSError.contextCreationFailed
        }

        self.context = createdContext
    }

    deinit {
        adb_tls_destroy(context)
    }

    func handshake() throws -> ADBTLSOperationResult {
        guard let context else {
            throw ADBTLSError.missingContext
        }

        return try Self.operationResult(adb_tls_handshake(context))
    }

    func provideEncryptedInput(_ bytes: [UInt8]) throws {
        guard let context else {
            throw ADBTLSError.missingContext
        }
        guard !bytes.isEmpty else {
            return
        }

        let accepted = bytes.withUnsafeBytes { buffer in
            adb_tls_provide_encrypted_input(
                context,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard accepted else {
            throw ADBTLSError.encryptedInputRejected
        }
    }

    func encryptedOutput() throws -> [UInt8] {
        guard let context else {
            throw ADBTLSError.missingContext
        }

        let pendingByteCount = adb_tls_pending_encrypted_output(context)
        guard pendingByteCount > 0 else {
            return []
        }

        var output = [UInt8](repeating: 0, count: pendingByteCount)
        let outputCapacity = output.count
        var outputByteCount = 0
        let copied = output.withUnsafeMutableBytes { outputBuffer in
            adb_tls_copy_encrypted_output(
                context,
                outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity,
                &outputByteCount
            )
        }
        guard copied, outputByteCount == output.count else {
            throw ADBTLSError.encryptedOutputUnavailable
        }

        return output
    }

    func writePlaintext(_ bytes: [UInt8]) throws -> ADBTLSWriteResult {
        guard let context else {
            throw ADBTLSError.missingContext
        }
        guard !bytes.isEmpty else {
            return ADBTLSWriteResult(operation: .complete, consumedByteCount: 0)
        }

        var consumedByteCount = 0
        let result = bytes.withUnsafeBytes { buffer in
            adb_tls_write_plaintext(
                context,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &consumedByteCount
            )
        }
        return ADBTLSWriteResult(
            operation: try Self.operationResult(result),
            consumedByteCount: consumedByteCount
        )
    }

    func readPlaintext(maximumByteCount: Int = 64 * 1024) throws -> ADBTLSReadResult {
        guard let context else {
            throw ADBTLSError.missingContext
        }
        guard maximumByteCount > 0 else {
            throw ADBTLSError.invalidMaximumReadByteCount(maximumByteCount)
        }

        var bytes = [UInt8](repeating: 0, count: maximumByteCount)
        let outputCapacity = bytes.count
        var outputByteCount = 0
        let result = bytes.withUnsafeMutableBytes { buffer in
            adb_tls_read_plaintext(
                context,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity,
                &outputByteCount
            )
        }
        guard outputByteCount <= bytes.count else {
            throw ADBTLSError.invalidPlaintextByteCount(outputByteCount)
        }

        return ADBTLSReadResult(
            operation: try Self.operationResult(result),
            bytes: Array(bytes.prefix(outputByteCount))
        )
    }

    var hasPeerCertificate: Bool {
        guard let context else {
            return false
        }

        return adb_tls_has_peer_certificate(context)
    }

    private static func operationResult(_ result: ADBTLSResult) throws -> ADBTLSOperationResult {
        switch result {
        case ADB_TLS_RESULT_COMPLETE:
            return .complete
        case ADB_TLS_RESULT_WANT_READ:
            return .wantRead
        case ADB_TLS_RESULT_WANT_WRITE:
            return .wantWrite
        case ADB_TLS_RESULT_CLOSED:
            return .closed
        default:
            throw ADBTLSError.operationFailed
        }
    }
}

enum ADBTLSOperationResult: Equatable, Sendable {
    case complete
    case wantRead
    case wantWrite
    case closed
}

struct ADBTLSWriteResult: Equatable, Sendable {
    var operation: ADBTLSOperationResult
    var consumedByteCount: Int
}

struct ADBTLSReadResult: Equatable, Sendable {
    var operation: ADBTLSOperationResult
    var bytes: [UInt8]
}

enum ADBTLSError: Error, Equatable, Sendable {
    case contextCreationFailed
    case missingContext
    case encryptedInputRejected
    case encryptedOutputUnavailable
    case invalidMaximumReadByteCount(Int)
    case invalidPlaintextByteCount(Int)
    case operationFailed
}
