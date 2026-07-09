#if canImport(Network)
import Dispatch
@preconcurrency import Network

public struct ADBDeviceConnection: Sendable {
    private let transport: ADBNetworkTransport
    public private(set) var session: ADBDeviceSession
    private var hasStarted: Bool

    public init(
        endpoint: ADBNetworkEndpoint,
        parameters: NWParameters = .tcp,
        queue: DispatchQueue = DispatchQueue(label: "ADBDeviceConnection")
    ) {
        let transport = ADBNetworkTransport(endpoint: endpoint, parameters: parameters, queue: queue)
        self.init(transport: transport)
    }

    init(transport: ADBNetworkTransport) {
        self.transport = transport
        self.session = ADBDeviceSession(transport: transport)
        self.hasStarted = false
    }

    public var connectionPhase: ADBConnectionPhase {
        session.connectionPhase
    }

    public mutating func start() {
        guard !hasStarted else {
            return
        }

        transport.start()
        hasStarted = true
    }

    public func cancel() {
        transport.cancel()
    }

    @discardableResult
    public mutating func connect(systemIdentity: String = "host::") async throws -> ADBConnectedDevice {
        start()
        return try await session.connect(systemIdentity: systemIdentity)
    }

    public mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        start()
        try await session.runShellCommand(command)
    }
}
#endif
