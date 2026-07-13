#if canImport(Security)
import CADBPairingCrypto
import Foundation
import Security

public struct ADBApplePairingIdentity: @unchecked Sendable {
    public let material: ADBPairingIdentityMaterial
    let securityIdentity: sec_identity_t
    let appleIdentity: SecIdentity

    init(
        material: ADBPairingIdentityMaterial,
        securityIdentity: sec_identity_t,
        appleIdentity: SecIdentity
    ) {
        self.material = material
        self.securityIdentity = securityIdentity
        self.appleIdentity = appleIdentity
    }
}

public extension ADBAppleAuthenticationIdentity {
    func pairingIdentity() throws -> ADBApplePairingIdentity {
        let privateKeyDER = try privateKeyExternalRepresentation()
        let certificateDER = try Self.generateCertificate(privateKeyDER: privateKeyDER)

        guard SecCertificateCreateWithData(nil, Data(certificateDER) as CFData) != nil else {
            throw ADBApplePairingIdentityError.invalidGeneratedCertificate
        }
        let identity = try Self.importIdentity(privateKeyDER: privateKeyDER)
        guard let networkIdentity = sec_identity_create(identity) else {
            throw ADBApplePairingIdentityError.networkIdentityCreationFailed
        }

        let material = try ADBPairingIdentityMaterial(
            authenticationPublicKey: publicKey(),
            certificatePEM: Self.pem(label: "CERTIFICATE", derBytes: certificateDER),
            privateKeyPEM: Self.pem(label: "RSA PRIVATE KEY", derBytes: privateKeyDER)
        )
        return ADBApplePairingIdentity(
            material: material,
            securityIdentity: networkIdentity,
            appleIdentity: identity
        )
    }

    private static let pkcs12Password = "adbtv-ephemeral-pkcs12"

    private static func importIdentity(privateKeyDER: [UInt8]) throws -> SecIdentity {
        let pkcs12DER = try generatePKCS12(privateKeyDER: privateKeyDER)
        let options = [kSecImportExportPassphrase as String: pkcs12Password]
        var importedItems: CFArray?
        let status = SecPKCS12Import(
            Data(pkcs12DER) as CFData,
            options as CFDictionary,
            &importedItems
        )
        guard status == errSecSuccess,
              let items = importedItems as? [[String: Any]],
              let identityValue = items.first?[kSecImportItemIdentity as String] else {
            throw ADBApplePairingIdentityError.identityImportFailed(status)
        }

        return try importedIdentity(from: identityValue)
    }

    static func importedIdentity(from value: Any) throws -> SecIdentity {
        guard let identity = value as? SecIdentity else {
            throw ADBApplePairingIdentityError.invalidImportedIdentity
        }
        return identity
    }

    private static func generatePKCS12(privateKeyDER: [UInt8]) throws -> [UInt8] {
        var pkcs12DER = [UInt8](
            repeating: 0,
            count: Int(ADB_PAIRING_CRYPTO_MAX_PKCS12_BYTE_COUNT)
        )
        let pkcs12Capacity = pkcs12DER.count
        var pkcs12ByteCount = 0

        let generated = privateKeyDER.withUnsafeBytes { privateKeyBuffer in
            pkcs12DER.withUnsafeMutableBytes { pkcs12Buffer in
                pkcs12Password.withCString { password in
                    adb_pairing_crypto_generate_pkcs12(
                        privateKeyBuffer.bindMemory(to: UInt8.self).baseAddress,
                        privateKeyDER.count,
                        password,
                        pkcs12Buffer.bindMemory(to: UInt8.self).baseAddress,
                        pkcs12Capacity,
                        &pkcs12ByteCount
                    )
                }
            }
        }
        guard generated, pkcs12ByteCount > 0 else {
            throw ADBApplePairingIdentityError.pkcs12GenerationFailed
        }

        return Array(pkcs12DER.prefix(pkcs12ByteCount))
    }

    private static func generateCertificate(privateKeyDER: [UInt8]) throws -> [UInt8] {
        var certificateDER = [UInt8](
            repeating: 0,
            count: Int(ADB_PAIRING_CRYPTO_MAX_CERTIFICATE_BYTE_COUNT)
        )
        let certificateCapacity = certificateDER.count
        var certificateByteCount = 0

        let generated = privateKeyDER.withUnsafeBytes { privateKeyBuffer in
            certificateDER.withUnsafeMutableBytes { certificateBuffer in
                adb_pairing_crypto_generate_certificate(
                    privateKeyBuffer.bindMemory(to: UInt8.self).baseAddress,
                    privateKeyDER.count,
                    certificateBuffer.bindMemory(to: UInt8.self).baseAddress,
                    certificateCapacity,
                    &certificateByteCount
                )
            }
        }
        guard generated, certificateByteCount > 0 else {
            throw ADBApplePairingIdentityError.certificateGenerationFailed
        }

        return Array(certificateDER.prefix(certificateByteCount))
    }

    private static func pem(label: String, derBytes: [UInt8]) -> [UInt8] {
        let base64 = Data(derBytes).base64EncodedString()
        var lines: [String] = []
        var start = base64.startIndex
        while start < base64.endIndex {
            let end = base64.index(start, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[start ..< end]))
            start = end
        }

        let value = (["-----BEGIN \(label)-----"] + lines + ["-----END \(label)-----", ""])
            .joined(separator: "\n")
        return Array(value.utf8)
    }
}

public enum ADBApplePairingIdentityError: Error, Equatable, Sendable {
    case certificateGenerationFailed
    case pkcs12GenerationFailed
    case invalidGeneratedCertificate
    case identityImportFailed(OSStatus)
    case invalidImportedIdentity
    case networkIdentityCreationFailed
}
#endif
