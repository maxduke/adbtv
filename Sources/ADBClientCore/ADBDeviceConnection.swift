#if canImport(Network)
import Dispatch
import Foundation
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
                var driver = ADBClientDriver(authenticationIdentity: authenticationIdentity)

                networkTransport.start()
                let connectOutput = try driver.startConnection(systemIdentity: systemIdentity)
                try await networkTransport.send(connectOutput.bytesToSend)

                let initialFrame = try await receiveInitialFrame(from: networkTransport)
                switch initialFrame.packet.command {
                case .secureTLS:
                    let secureTransportOutput = try driver.receiveBytes(
                        try initialFrame.packet.encoded()
                    )
                    try await networkTransport.send(secureTransportOutput.bytesToSend)

                    let pairingIdentity = try authenticationIdentity.pairingIdentity()
                    let tlsTransport = try await ADBTLSByteTransport.upgrade(
                        underlying: networkTransport,
                        identity: pairingIdentity.material,
                        initialEncryptedInput: initialFrame.trailingBytes
                    )
                    return try await finishConnection(
                        networkTransport: networkTransport,
                        byteTransport: tlsTransport,
                        driver: driver
                    )

                case .auth, .connect:
                    let initialOutput = try driver.receiveBytes(
                        try initialFrame.packet.encoded() + initialFrame.trailingBytes
                    )
                    try await networkTransport.send(initialOutput.bytesToSend)
                    return try await finishConnection(
                        networkTransport: networkTransport,
                        byteTransport: networkTransport,
                        driver: driver,
                        initialOutput: initialOutput
                    )

                default:
                    throw ADBWirelessDebuggingConnectionError.unexpectedInitialCommand(
                        initialFrame.packet.command
                    )
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

    public mutating func runService(
        _ service: String,
        maximumOutputByteCount: Int
    ) async throws -> ADBServiceOutput {
        start()
        return try await session.runService(
            service,
            maximumOutputByteCount: maximumOutputByteCount
        )
    }

    public mutating func listDirectory(
        _ path: ADBRemotePath
    ) async throws -> [ADBSyncDirectoryEntry] {
        start()
        return try await session.listDirectory(path)
    }

    public mutating func pullFile(
        _ remotePath: ADBRemotePath,
        to localURL: URL,
        expectedByteCount: Int64? = nil,
        eventHandler: @escaping ADBSyncPullEventHandler = { _ in }
    ) async throws -> Int64 {
        start()
        return try await session.pullFile(
            remotePath,
            to: localURL,
            expectedByteCount: expectedByteCount,
            eventHandler: eventHandler
        )
    }

    public mutating func pushFile(
        from localURL: URL,
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler = { _ in }
    ) async throws -> [ADBSyncPushEvent] {
        start()
        return try await session.pushFile(
            from: localURL,
            plan: plan,
            eventHandler: eventHandler
        )
    }

    public mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32 = 0,
        installer: ADBAPKInstaller = ADBAPKInstaller(),
        eventHandler: @escaping ADBAPKInstallEventHandler = { _ in }
    ) async throws -> ADBAPKInstallReport {
        start()
        return try await session.installAPK(
            contents: contents,
            plan: plan,
            modificationTime: modificationTime,
            installer: installer,
            eventHandler: eventHandler
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
                        throw ADBWirelessDebuggingConnectionError.transportClosedBeforeInitialResponse
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

    private static func finishConnection(
        networkTransport: ADBNetworkTransport,
        byteTransport: any ADBByteTransport,
        driver: ADBClientDriver,
        initialOutput: ADBClientDriverOutput? = nil
    ) async throws -> ADBDeviceConnection {
        var transportSession = ADBTransportSession(driver: driver, transport: byteTransport)
        if let initialOutput,
           ADBTransportSessionOutput(driverOutput: initialOutput).connectedDevice != nil {
            return ADBDeviceConnection(
                transport: networkTransport,
                session: ADBDeviceSession(transportSession: transportSession),
                hasStarted: true
            )
        }

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
    }
}

extension ADBDeviceConnection: ADBShellCommandRunningSession {}

private struct ADBInitialConnectionFrame {
    static let maximumBufferedByteCount = 64 * 1024

    var packet: ADBPacket
    var trailingBytes: [UInt8]
}

public enum ADBWirelessDebuggingConnectionError: Error, Equatable, Sendable {
    case transportClosedBeforeInitialResponse
    case initialFrameTooLarge(Int)
    case unexpectedInitialCommand(ADBCommand)
    case transportClosedBeforeConnection
}
#endif
