#if canImport(Network)
import Dispatch
import Foundation
@preconcurrency import Network

public final class ADBNetworkTransport: ADBByteTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let maximumReceiveLength: Int

    public convenience init(
        endpoint: ADBNetworkEndpoint,
        parameters: NWParameters = .tcp,
        queue: DispatchQueue = DispatchQueue(label: "ADBNetworkTransport")
    ) {
        self.init(
            connection: NWConnection(to: endpoint.nwEndpoint, using: parameters),
            queue: queue
        )
    }

    init(
        connection: NWConnection,
        queue: DispatchQueue = DispatchQueue(label: "ADBNetworkTransport"),
        maximumReceiveLength: Int = 64 * 1024
    ) {
        self.connection = connection
        self.queue = queue
        self.maximumReceiveLength = maximumReceiveLength
    }

    public func start() {
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8]?, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumReceiveLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let data, !data.isEmpty {
                    continuation.resume(returning: Array(data))
                    return
                }

                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: [])
            }
        }
    }
}
#endif
