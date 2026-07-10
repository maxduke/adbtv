#if canImport(Network) && canImport(Security)
@testable import ADBClientCore
import Dispatch
import Network
import Security
import XCTest

final class ADBPairingTLSConnectionTests: XCTestCase {
    func testExporterConstantsMatchAOSPChannelBinding() {
        XCTAssertEqual(
            ADBPairingTLSConnection.exporterLabel,
            Array("adb-label".utf8) + [0]
        )
        XCTAssertEqual(ADBPairingTLSConnection.exporterByteCount, 64)
    }

    func testParametersContainTLSOverTCP() throws {
        let identity = try makeAuthenticationIdentity().pairingIdentity()
        let parameters = ADBPairingTLSConnection.parameters(
            identity: identity,
            verifyQueue: DispatchQueue(label: "ADBPairingTLSConnectionTests")
        )

        XCTAssertTrue(parameters.defaultProtocolStack.transportProtocol is NWProtocolTCP.Options)
        XCTAssertTrue(
            parameters.defaultProtocolStack.applicationProtocols.contains {
                $0 is NWProtocolTLS.Options
            }
        )
    }

    func testLoopbackTLSConnectionExportsMatchingKeyMaterial() async throws {
        let serverIdentity = try makeAuthenticationIdentity().pairingIdentity()
        let clientIdentity = try makeAuthenticationIdentity().pairingIdentity()
        let queue = DispatchQueue(label: "ADBPairingTLSConnectionTests.loopback")
        let verificationQueue = DispatchQueue(
            label: "ADBPairingTLSConnectionTests.loopbackVerification"
        )
        let listener = try NWListener(
            using: ADBPairingTLSConnection.parameters(
                identity: serverIdentity,
                verifyQueue: verificationQueue
            ),
            on: .any
        )
        defer { listener.cancel() }

        let serverExporter = AsyncThrowingStream<[UInt8], Error> { continuation in
            listener.newConnectionHandler = { connection in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        do {
                            let exporter = try ADBPairingTLSConnection.exportedKeyMaterial(
                                connection: connection
                            )
                            connection.stateUpdateHandler = nil
                            continuation.yield(exporter)
                            continuation.finish()
                            connection.cancel()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    case let .failed(error):
                        continuation.finish(throwing: error)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }

        try await start(listener: listener, queue: queue)
        guard let port = listener.port?.rawValue else {
            XCTFail("Expected loopback listener to expose a port.")
            return
        }

        let client = try await ADBPairingTLSConnection.connect(
            endpoint: ADBNetworkEndpoint(host: "127.0.0.1", port: port),
            identity: clientIdentity,
            queue: queue
        )
        defer { client.cancel() }

        var iterator = serverExporter.makeAsyncIterator()
        guard let remoteExporter = try await iterator.next() else {
            XCTFail("Expected the loopback server to export key material.")
            return
        }
        XCTAssertEqual(remoteExporter, client.tlsExporter)
        XCTAssertEqual(client.tlsExporter.count, 64)
    }

    private func start(listener: NWListener, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func makeAuthenticationIdentity() throws -> ADBAppleAuthenticationIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return ADBAppleAuthenticationIdentity(privateKey: key)
    }
}
#endif
