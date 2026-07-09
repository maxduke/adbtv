@testable import ADBClientCore

struct TestAuthenticationIdentity: ADBAuthenticationIdentity {
    var signature: [UInt8]
    var publicKey: ADBAuthenticationPublicKey

    func signature(for token: [UInt8]) throws -> [UInt8] {
        signature + token
    }

    func publicKey() throws -> ADBAuthenticationPublicKey {
        publicKey
    }
}
