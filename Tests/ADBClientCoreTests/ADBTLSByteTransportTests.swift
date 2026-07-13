#if canImport(Network) && canImport(Security)
@testable import ADBClientCore
import Dispatch
import Network
import Security
import XCTest

final class ADBTLSByteTransportTests: XCTestCase {
    func testLoopbackTransportUpgradesAndExchangesPlaintext() async throws {
        let queue = DispatchQueue(label: "ADBTLSByteTransportTests.loopback")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        let acceptedTransports = AsyncStream<ADBNetworkTransport> { continuation in
            listener.newConnectionHandler = { connection in
                let transport = ADBNetworkTransport(connection: connection, queue: queue)
                transport.start()
                continuation.yield(transport)
                continuation.finish()
            }
        }
        try await start(listener: listener, queue: queue)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let clientNetworkTransport = ADBNetworkTransport(
            endpoint: ADBNetworkEndpoint(host: "127.0.0.1", port: port),
            queue: queue
        )
        defer { clientNetworkTransport.cancel() }

        async let clientTransport = ADBTLSByteTransport.upgrade(
            underlying: clientNetworkTransport,
            identity: makeIdentityMaterial(),
            role: .client
        )
        var iterator = acceptedTransports.makeAsyncIterator()
        let serverNetworkTransport = await iterator.next()
        let unwrappedServerNetworkTransport = try XCTUnwrap(serverNetworkTransport)
        defer { unwrappedServerNetworkTransport.cancel() }
        async let serverTransport = ADBTLSByteTransport.upgrade(
            underlying: unwrappedServerNetworkTransport,
            identity: makeIdentityMaterial(),
            role: .server
        )

        let (client, server) = try await (clientTransport, serverTransport)
        let clientMessage = Array("client payload".utf8)
        try await client.send(clientMessage)
        let receivedClientMessage = try await server.receive()
        XCTAssertEqual(receivedClientMessage, clientMessage)

        let serverMessage = Array("server payload".utf8)
        try await server.send(serverMessage)
        let receivedServerMessage = try await client.receive()
        XCTAssertEqual(receivedServerMessage, serverMessage)
    }

    private func start(listener: NWListener, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
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

    private func makeIdentityMaterial() throws -> ADBPairingIdentityMaterial {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }

        return try ADBAppleAuthenticationIdentity(privateKey: key).pairingIdentity().material
    }
}
#endif
