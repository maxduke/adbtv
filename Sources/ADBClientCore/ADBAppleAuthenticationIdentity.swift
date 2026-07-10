#if canImport(Security)
import Foundation
import Security

public struct ADBAppleAuthenticationIdentity: ADBAuthenticationIdentity, @unchecked Sendable {
    public static let adbTokenByteCount = 20

    private let privateKey: SecKey
    private let publicKeyComment: String

    public init(privateKey: SecKey, publicKeyComment: String = "adbtv@ios") {
        self.privateKey = privateKey
        self.publicKeyComment = publicKeyComment
    }

    public func signature(for token: [UInt8]) throws -> [UInt8] {
        guard token.count == Self.adbTokenByteCount else {
            throw ADBAppleAuthenticationIdentityError.invalidTokenByteCount(token.count)
        }

        let algorithm = SecKeyAlgorithm.rsaSignatureDigestPKCS1v15SHA1
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw ADBAppleAuthenticationIdentityError.unsupportedSigningAlgorithm
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, Data(token) as CFData, &error) else {
            throw ADBAppleAuthenticationIdentityError.signingFailed(describe(error))
        }

        return Array(signature as Data)
    }

    public func publicKey() throws -> ADBAuthenticationPublicKey {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw ADBAppleAuthenticationIdentityError.missingPublicKey
        }

        var error: Unmanaged<CFError>?
        guard let externalRepresentation = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw ADBAppleAuthenticationIdentityError.publicKeyExportFailed(describe(error))
        }

        let components = try ADBRSAKeyEncoder.componentsFromDEREncodedPublicKey(
            Array(externalRepresentation as Data)
        )
        return try ADBRSAKeyEncoder.androidPublicKey(
            components: components,
            comment: publicKeyComment
        )
    }

    func privateKeyExternalRepresentation() throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let externalRepresentation = SecKeyCopyExternalRepresentation(privateKey, &error) else {
            throw ADBAppleAuthenticationIdentityError.privateKeyExportFailed(describe(error))
        }

        return Array(externalRepresentation as Data)
    }

    var securityPrivateKey: SecKey {
        privateKey
    }
}

public struct ADBAppleAuthenticationIdentityStore: Sendable {
    public var applicationTag: String
    public var publicKeyComment: String
    public var synchronizable: Bool

    public init(
        applicationTag: String = "com.adbtv.adb.identity",
        publicKeyComment: String = "adbtv@ios",
        synchronizable: Bool = true
    ) {
        self.applicationTag = applicationTag
        self.publicKeyComment = publicKeyComment
        self.synchronizable = synchronizable
    }

    public func loadOrCreateIdentity() throws -> ADBAppleAuthenticationIdentity {
        if let identity = try loadIdentity() {
            return identity
        }

        return try createIdentity()
    }

    public func loadIdentity() throws -> ADBAppleAuthenticationIdentity? {
        var query = baseKeychainQuery()
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let result else {
                throw ADBAppleAuthenticationIdentityError.invalidKeychainItem
            }
            let privateKey = result as! SecKey
            return ADBAppleAuthenticationIdentity(privateKey: privateKey, publicKeyComment: publicKeyComment)

        case errSecItemNotFound:
            return nil

        default:
            throw ADBAppleAuthenticationIdentityError.keyLookupFailed(status)
        }
    }

    public func createIdentity() throws -> ADBAppleAuthenticationIdentity {
        var privateKeyAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTagData
        ]

        if synchronizable {
            privateKeyAttributes[kSecAttrSynchronizable as String] = true
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: ADBRSAPublicKeyComponents.adbModulusByteCount * 8,
            kSecPrivateKeyAttrs as String: privateKeyAttributes
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw ADBAppleAuthenticationIdentityError.keyGenerationFailed(describe(error))
        }

        return ADBAppleAuthenticationIdentity(privateKey: privateKey, publicKeyComment: publicKeyComment)
    }

    private var applicationTagData: Data {
        Data(applicationTag.utf8)
    }

    private func baseKeychainQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrApplicationTag as String: applicationTagData
        ]

        if synchronizable {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }

        return query
    }
}

public enum ADBAppleAuthenticationIdentityError: Error, Equatable, Sendable {
    case invalidTokenByteCount(Int)
    case unsupportedSigningAlgorithm
    case signingFailed(String)
    case missingPublicKey
    case publicKeyExportFailed(String)
    case privateKeyExportFailed(String)
    case keyLookupFailed(OSStatus)
    case invalidKeychainItem
    case keyGenerationFailed(String)
}

private func describe(_ error: Unmanaged<CFError>?) -> String {
    guard let error else {
        return "unknown Security framework error"
    }

    let retainedError = error.takeRetainedValue()
    return CFErrorCopyDescription(retainedError) as String
}
#endif
