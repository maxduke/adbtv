#if canImport(Network) && canImport(Security)
import Dispatch
import Foundation
@preconcurrency import Network
import Security

public final class ADBPairingTLSConnection: @unchecked Sendable {
    public static let exporterByteCount = 64
    public static let exporterLabel = Array("adb-label".utf8) + [UInt8(0)]
    private static let verificationQueue = DispatchQueue(
        label: "ADBPairingTLSConnection.Verification"
    )

    public let transport: ADBNetworkTransport
    public let tlsExporter: [UInt8]

    private init(transport: ADBNetworkTransport, tlsExporter: [UInt8]) {
        self.transport = transport
        self.tlsExporter = tlsExporter
    }

    public static func connect(
        endpoint: ADBNetworkEndpoint,
        identity: ADBApplePairingIdentity,
        queue: DispatchQueue = DispatchQueue(label: "ADBPairingTLSConnection")
    ) async throws -> ADBPairingTLSConnection {
        let connection = NWConnection(
            to: endpoint.nwEndpoint,
            using: parameters(identity: identity, verifyQueue: verificationQueue)
        )
        let transport = ADBNetworkTransport(connection: connection, queue: queue)

        do {
            try await waitUntilReady(connection: connection, transport: transport)
            let exporter = try exportedKeyMaterial(connection: connection)
            return ADBPairingTLSConnection(transport: transport, tlsExporter: exporter)
        } catch {
            transport.cancel()
            throw error
        }
    }

    public func cancel() {
        transport.cancel()
    }

    static func parameters(
        identity: ADBApplePairingIdentity,
        verifyQueue: DispatchQueue
    ) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_local_identity(securityOptions, identity.securityIdentity)
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)

        // SPAKE2 authenticates the peer after this anonymous TLS channel is established.
        sec_protocol_options_set_verify_block(securityOptions, { _, _, completion in
            completion(true)
        }, verifyQueue)

        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    static func exportedKeyMaterial(connection: NWConnection) throws -> [UInt8] {
        guard let tlsMetadata = connection.metadata(definition: NWProtocolTLS.definition)
            as? NWProtocolTLS.Metadata else {
            throw ADBPairingTLSConnectionError.missingTLSMetadata
        }

        let exportedSecret = exporterLabel.withUnsafeBytes { labelBuffer in
            sec_protocol_metadata_create_secret(
                tlsMetadata.securityProtocolMetadata,
                exporterLabel.count,
                labelBuffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                exporterByteCount
            )
        }
        guard let exportedSecret else {
            throw ADBPairingTLSConnectionError.exportFailed
        }

        let dispatchData = exportedSecret as DispatchData
        let bytes = dispatchData.withUnsafeBytes { (pointer: UnsafePointer<UInt8>) -> [UInt8] in
            Array(UnsafeBufferPointer(start: pointer, count: dispatchData.count))
        }
        guard bytes.count == exporterByteCount else {
            throw ADBPairingTLSConnectionError.invalidExporterByteCount(bytes.count)
        }

        return bytes
    }

    private static func waitUntilReady(
        connection: NWConnection,
        transport: ADBNetworkTransport
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    case let .failed(error):
                        connection.stateUpdateHandler = nil
                        continuation.resume(
                            throwing: ADBPairingTLSConnectionError.connectionFailed(
                                String(describing: error)
                            )
                        )
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: ADBPairingTLSConnectionError.cancelled)
                    default:
                        break
                    }
                }
                transport.start()
            }
        } onCancel: {
            transport.cancel()
        }
    }
}

public enum ADBPairingTLSConnectionError: Error, Equatable, Sendable {
    case connectionFailed(String)
    case cancelled
    case missingTLSMetadata
    case exportFailed
    case invalidExporterByteCount(Int)
}
#endif
