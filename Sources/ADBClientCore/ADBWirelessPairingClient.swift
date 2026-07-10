#if canImport(CryptoKit) && canImport(Network) && canImport(Security)
import Dispatch

public struct ADBWirelessPairingClient: Sendable {
    public var identityStore: ADBAppleAuthenticationIdentityStore

    public init(
        identityStore: ADBAppleAuthenticationIdentityStore = ADBAppleAuthenticationIdentityStore()
    ) {
        self.identityStore = identityStore
    }

    public func pair(
        endpoint: ADBNetworkEndpoint,
        secret: ADBPairingSecret,
        queue: DispatchQueue = DispatchQueue(label: "ADBWirelessPairingClient")
    ) async throws -> ADBPairingPeerInfo {
        try await pair(target: .hostPort(endpoint), secret: secret, queue: queue)
    }

    public func pair(
        target: ADBNetworkTarget,
        secret: ADBPairingSecret,
        queue: DispatchQueue = DispatchQueue(label: "ADBWirelessPairingClient")
    ) async throws -> ADBPairingPeerInfo {
        let authenticationIdentity = try identityStore.loadOrCreateIdentity()
        let pairingIdentity = try authenticationIdentity.pairingIdentity()
        let tlsConnection = try await ADBPairingTLSConnection.connect(
            target: target,
            identity: pairingIdentity,
            queue: queue
        )
        defer { tlsConnection.cancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let keyExchange = try ADBBoringSSLPairingKeyExchange(
                secret: secret,
                tlsExporter: tlsConnection.tlsExporter
            )
            var pairingClient = ADBPairingClient(
                session: ADBPairingProtocolSession(
                    identityMaterial: pairingIdentity.material,
                    keyExchange: keyExchange
                ),
                transport: tlsConnection.transport
            )
            return try await pairingClient.pair()
        } onCancel: {
            tlsConnection.cancel()
        }
    }
}
#endif
