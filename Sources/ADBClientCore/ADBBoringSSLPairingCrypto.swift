#if canImport(CryptoKit)
import CADBPairingCrypto
import CryptoKit
import Foundation

public final class ADBBoringSSLPairingKeyExchange: ADBPairingKeyExchange, @unchecked Sendable {
    public static let tlsExporterByteCount = 64
    public static let spake2MessageByteCount = Int(ADB_PAIRING_CRYPTO_MESSAGE_BYTE_COUNT)

    private let lock = NSLock()
    private var context: OpaquePointer?
    private var didReadLocalMessage = false
    private var didInitializeCipher = false

    public convenience init(
        secret: ADBPairingSecret,
        tlsExporter: [UInt8]
    ) throws {
        guard tlsExporter.count == Self.tlsExporterByteCount else {
            throw ADBPairingCryptoError.invalidTLSExporterByteCount(tlsExporter.count)
        }

        try self.init(role: .client, password: secret.bytes + tlsExporter)
    }

    init(role: ADBPairingCryptoRole, password: [UInt8]) throws {
        guard !password.isEmpty else {
            throw ADBPairingCryptoError.emptyPassword
        }

        let createdContext = password.withUnsafeBytes { passwordBuffer in
            let baseAddress = passwordBuffer.bindMemory(to: UInt8.self).baseAddress
            switch role {
            case .client:
                return adb_pairing_crypto_client_create(baseAddress, password.count)
            case .server:
                return adb_pairing_crypto_server_create(baseAddress, password.count)
            }
        }
        guard let createdContext else {
            throw ADBPairingCryptoError.contextCreationFailed
        }

        self.context = createdContext
    }

    deinit {
        adb_pairing_crypto_destroy(context)
    }

    public func localSPAKE2Message() throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        guard !didReadLocalMessage else {
            throw ADBPairingCryptoError.localMessageAlreadyRead
        }
        guard let context else {
            throw ADBPairingCryptoError.missingContext
        }

        var message = [UInt8](repeating: 0, count: Self.spake2MessageByteCount)
        let copied = message.withUnsafeMutableBytes { messageBuffer in
            adb_pairing_crypto_copy_message(
                context,
                messageBuffer.bindMemory(to: UInt8.self).baseAddress
            )
        }
        guard copied else {
            throw ADBPairingCryptoError.localMessageUnavailable
        }

        didReadLocalMessage = true
        return message
    }

    public func initializeCipher(
        peerSPAKE2Message: [UInt8]
    ) throws -> any ADBPairingCipher {
        lock.lock()
        defer { lock.unlock() }

        guard didReadLocalMessage else {
            throw ADBPairingCryptoError.localMessageNotRead
        }
        guard !didInitializeCipher else {
            throw ADBPairingCryptoError.cipherAlreadyInitialized
        }
        guard peerSPAKE2Message.count == Self.spake2MessageByteCount else {
            throw ADBPairingCryptoError.invalidPeerMessageByteCount(peerSPAKE2Message.count)
        }
        guard let context else {
            throw ADBPairingCryptoError.missingContext
        }

        var keyMaterial = [UInt8](
            repeating: 0,
            count: Int(ADB_PAIRING_CRYPTO_KEY_MATERIAL_BYTE_COUNT)
        )
        let succeeded = peerSPAKE2Message.withUnsafeBytes { peerBuffer in
            keyMaterial.withUnsafeMutableBytes { keyBuffer in
                adb_pairing_crypto_process_message(
                    context,
                    peerBuffer.bindMemory(to: UInt8.self).baseAddress,
                    peerSPAKE2Message.count,
                    keyBuffer.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        adb_pairing_crypto_destroy(context)
        self.context = nil
        didInitializeCipher = true
        guard succeeded else {
            throw ADBPairingCryptoError.keyAgreementFailed
        }

        return ADBCryptoKitPairingCipher(keyMaterial: keyMaterial)
    }
}

enum ADBPairingCryptoRole {
    case client
    case server
}

public final class ADBCryptoKitPairingCipher: ADBPairingCipher, @unchecked Sendable {
    public static let authenticationTagByteCount = 16
    private static let nonceByteCount = 12
    private static let hkdfInfo = Data("adb pairing_auth aes-128-gcm key".utf8)

    private let lock = NSLock()
    private let key: SymmetricKey
    private var encryptionSequence: UInt64 = 0
    private var decryptionSequence: UInt64 = 0

    init(keyMaterial: [UInt8]) {
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyMaterial),
            salt: Data(),
            info: Self.hkdfInfo,
            outputByteCount: 16
        )
    }

    public func encrypt(_ plaintext: [UInt8]) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        let sequence = encryptionSequence
        guard sequence < UInt64.max else {
            throw ADBPairingCryptoError.encryptionSequenceExhausted
        }

        do {
            let nonce = try AES.GCM.Nonce(data: Self.nonce(sequence: sequence))
            let sealed = try AES.GCM.seal(Data(plaintext), using: key, nonce: nonce)
            encryptionSequence += 1
            return Array(sealed.ciphertext) + Array(sealed.tag)
        } catch {
            throw ADBPairingCryptoError.encryptionFailed
        }
    }

    public func decrypt(_ ciphertext: [UInt8]) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        guard ciphertext.count >= Self.authenticationTagByteCount else {
            throw ADBPairingCryptoError.ciphertextTooShort(ciphertext.count)
        }
        let sequence = decryptionSequence
        guard sequence < UInt64.max else {
            throw ADBPairingCryptoError.decryptionSequenceExhausted
        }

        do {
            let nonce = try AES.GCM.Nonce(data: Self.nonce(sequence: sequence))
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: Data(ciphertext.dropLast(Self.authenticationTagByteCount)),
                tag: Data(ciphertext.suffix(Self.authenticationTagByteCount))
            )
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            decryptionSequence += 1
            return Array(plaintext)
        } catch {
            throw ADBPairingCryptoError.decryptionFailed
        }
    }

    private static func nonce(sequence: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceByteCount)
        for index in 0 ..< MemoryLayout<UInt64>.size {
            bytes[index] = UInt8((sequence >> UInt64(index * 8)) & 0xFF)
        }
        return Data(bytes)
    }
}

public enum ADBPairingCryptoError: Error, Equatable, Sendable {
    case invalidTLSExporterByteCount(Int)
    case emptyPassword
    case contextCreationFailed
    case missingContext
    case localMessageAlreadyRead
    case localMessageUnavailable
    case localMessageNotRead
    case cipherAlreadyInitialized
    case invalidPeerMessageByteCount(Int)
    case keyAgreementFailed
    case encryptionSequenceExhausted
    case decryptionSequenceExhausted
    case ciphertextTooShort(Int)
    case encryptionFailed
    case decryptionFailed
}
#endif
