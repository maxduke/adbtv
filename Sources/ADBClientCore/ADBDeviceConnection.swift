#if canImport(Network)
import Dispatch
@preconcurrency import Network
#if canImport(Security)
import Security
#endif

public struct ADBDeviceConnection: Sendable {
    private let transport: ADBNetworkTransport
    public private(set) var session: ADBDeviceSession
    private var hasStarted: Bool

    public init(
        endpoint: ADBNetworkEndpoint,
        parameters: NWParameters = .tcp,
        queue: DispatchQueue = DispatchQueue(label: "ADBDeviceConnection")
    ) {
        self.init(endpoint: endpoint, authenticationIdentity: nil, parameters: parameters, queue: queue)
    }

    public init(
        endpoint: ADBNetworkEndpoint,
        authenticationIdentity: (any ADBAuthenticationIdentity)?,
        parameters: NWParameters = .tcp,
        queue: DispatchQueue = DispatchQueue(label: "ADBDeviceConnection")
    ) {
        let transport = ADBNetworkTransport(endpoint: endpoint, parameters: parameters, queue: queue)
        let driver: ADBClientDriver
        if let authenticationIdentity {
            driver = ADBClientDriver(authenticationIdentity: authenticationIdentity)
        } else {
            driver = ADBClientDriver()
        }
        self.init(transport: transport, driver: driver)
    }

#if canImport(Security)
    public init(
        authenticatedEndpoint endpoint: ADBNetworkEndpoint,
        identityStore: ADBAppleAuthenticationIdentityStore = ADBAppleAuthenticationIdentityStore(),
        parameters: NWParameters = .tcp,
        queue: DispatchQueue = DispatchQueue(label: "ADBDeviceConnection")
    ) throws {
        try self.init(
            endpoint: endpoint,
            authenticationIdentity: identityStore.loadOrCreateIdentity(),
            parameters: parameters,
            queue: queue
        )
    }
#endif

    init(transport: ADBNetworkTransport, driver: ADBClientDriver = ADBClientDriver()) {
        self.transport = transport
        self.session = ADBDeviceSession(driver: driver, transport: transport)
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
        return try await session.runShellCommand(command)
    }
}
#endif
