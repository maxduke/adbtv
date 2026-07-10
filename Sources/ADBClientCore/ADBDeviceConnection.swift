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

    public static func connectedToWirelessDebugging(
        target: ADBNetworkTarget,
        identityStore: ADBAppleAuthenticationIdentityStore = ADBAppleAuthenticationIdentityStore(),
        systemIdentity: String = "host::",
        queue: DispatchQueue = DispatchQueue(label: "ADBDeviceConnection.WirelessDebugging")
    ) async throws -> ADBDeviceConnection {
        try await connectedToWirelessDebugging(
            target: target,
            authenticationIdentity: identityStore.loadOrCreateIdentity(),
            systemIdentity: systemIdentity,
            queue: queue
        )
    }

    static func connectedToWirelessDebugging(
        target: ADBNetworkTarget,
        authenticationIdentity: ADBAppleAuthenticationIdentity,
        systemIdentity: String = "host::",
        queue: DispatchQueue = DispatchQueue(label: "ADBDeviceConnection.WirelessDebugging")
    ) async throws -> ADBDeviceConnection {
        let networkTransport = ADBNetworkTransport(target: target, queue: queue)

        return try await withTaskCancellationHandler {
            do {
                let pairingIdentity = try authenticationIdentity.pairingIdentity()
                var driver = ADBClientDriver()

                networkTransport.start()
                let connectOutput = try driver.startConnection(systemIdentity: systemIdentity)
                try await networkTransport.send(connectOutput.bytesToSend)

                let initialFrame = try await receiveInitialFrame(from: networkTransport)
                let secureTransportOutput = try driver.receiveBytes(
                    try initialFrame.packet.encoded()
                )
                guard secureTransportOutput.actions.contains(where: { action in
                    action.events.contains(where: { event in
                        if case .secureTransportRequested = event {
                            return true
                        }
                        return false
                    })
                }) else {
                    throw ADBWirelessDebuggingConnectionError.secureTransportNotRequested(
                        initialFrame.packet.command
                    )
                }
                try await networkTransport.send(secureTransportOutput.bytesToSend)

                let tlsTransport = try await ADBTLSByteTransport.upgrade(
                    underlying: networkTransport,
                    identity: pairingIdentity.material,
                    initialEncryptedInput: initialFrame.trailingBytes
                )
                var transportSession = ADBTransportSession(
                    driver: driver,
                    transport: tlsTransport
                )
                while true {
                    guard let output = try await transportSession.receiveNext() else {
                        throw ADBWirelessDebuggingConnectionError.transportClosedBeforeConnection
                    }
                    if output.connectedDevice != nil {
                        return ADBDeviceConnection(
                            transport: networkTransport,
                            session: ADBDeviceSession(transportSession: transportSession),
                            hasStarted: true
                        )
                    }
                }
            } catch {
                networkTransport.cancel()
                throw error
            }
        } onCancel: {
            networkTransport.cancel()
        }
    }
#endif

    init(transport: ADBNetworkTransport, driver: ADBClientDriver = ADBClientDriver()) {
        self.init(
            transport: transport,
            session: ADBDeviceSession(driver: driver, transport: transport),
            hasStarted: false
        )
    }

    private init(
        transport: ADBNetworkTransport,
        session: ADBDeviceSession,
        hasStarted: Bool
    ) {
        self.transport = transport
        self.session = session
        self.hasStarted = hasStarted
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
        if case let .connected(protocolVersion, maxData, banner) = connectionPhase {
            return ADBConnectedDevice(
                protocolVersion: protocolVersion,
                maxData: maxData,
                banner: banner
            )
        }

        start()
        return try await session.connect(systemIdentity: systemIdentity)
    }

    public mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        start()
        return try await session.runShellCommand(command)
    }

    public mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32 = 0,
        installer: ADBAPKInstaller = ADBAPKInstaller()
    ) async throws -> ADBAPKInstallReport {
        start()
        return try await session.installAPK(
            contents: contents,
            plan: plan,
            modificationTime: modificationTime,
            installer: installer
        )
    }

    private static func receiveInitialFrame(
        from transport: ADBNetworkTransport
    ) async throws -> ADBInitialConnectionFrame {
        var bufferedBytes: [UInt8] = []

        while true {
            do {
                let decodedFrame = try ADBPacket.decodeFrame(from: bufferedBytes)
                return ADBInitialConnectionFrame(
                    packet: decodedFrame.packet,
                    trailingBytes: Array(bufferedBytes.dropFirst(decodedFrame.consumedByteCount))
                )
            } catch let error as ADBPacketFramingError {
                switch error {
                case .incompleteHeader, .incompletePayload:
                    guard let bytes = try await transport.receive() else {
                        throw ADBWirelessDebuggingConnectionError.transportClosedBeforeSecureTransport
                    }
                    bufferedBytes.append(contentsOf: bytes)
                    guard bufferedBytes.count <= ADBInitialConnectionFrame.maximumBufferedByteCount else {
                        throw ADBWirelessDebuggingConnectionError.initialFrameTooLarge(
                            bufferedBytes.count
                        )
                    }
                default:
                    throw error
                }
            }
        }
    }
}

private struct ADBInitialConnectionFrame {
    static let maximumBufferedByteCount = 64 * 1024

    var packet: ADBPacket
    var trailingBytes: [UInt8]
}

public enum ADBWirelessDebuggingConnectionError: Error, Equatable, Sendable {
    case transportClosedBeforeSecureTransport
    case initialFrameTooLarge(Int)
    case secureTransportNotRequested(ADBCommand)
    case transportClosedBeforeConnection
}
#endif
