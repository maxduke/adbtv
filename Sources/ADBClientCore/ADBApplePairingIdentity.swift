#if canImport(Security)
import CADBPairingCrypto
import Foundation
import Security

public struct ADBApplePairingIdentity: @unchecked Sendable {
    public let material: ADBPairingIdentityMaterial
    let securityIdentity: sec_identity_t

    init(material: ADBPairingIdentityMaterial, securityIdentity: sec_identity_t) {
        self.material = material
        self.securityIdentity = securityIdentity
    }
}

public extension ADBAppleAuthenticationIdentity {
    func pairingIdentity() throws -> ADBApplePairingIdentity {
        let privateKeyDER = try privateKeyExternalRepresentation()
        let certificateDER = try Self.generateCertificate(privateKeyDER: privateKeyDER)

        guard let certificate = SecCertificateCreateWithData(nil, Data(certificateDER) as CFData) else {
            throw ADBApplePairingIdentityError.invalidGeneratedCertificate
        }
        guard let identity = SecIdentityCreate(nil, certificate, securityPrivateKey) else {
            throw ADBApplePairingIdentityError.identityCreationFailed
        }

        let material = try ADBPairingIdentityMaterial(
            authenticationPublicKey: publicKey(),
            certificatePEM: Self.pem(label: "CERTIFICATE", derBytes: certificateDER),
            privateKeyPEM: Self.pem(label: "RSA PRIVATE KEY", derBytes: privateKeyDER)
        )
        return ADBApplePairingIdentity(
            material: material,
            securityIdentity: sec_identity_create(identity)
        )
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
    case invalidGeneratedCertificate
    case identityCreationFailed
}
#endif
