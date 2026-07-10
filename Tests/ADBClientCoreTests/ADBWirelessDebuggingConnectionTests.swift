#if canImport(Network) && canImport(Security)
@testable import ADBClientCore
import Dispatch
import Network
import Security
import XCTest

final class ADBWirelessDebuggingConnectionTests: XCTestCase {
    func testLoopbackSTARTTLSConnectionRunsShellCommand() async throws {
        let queue = DispatchQueue(label: "ADBWirelessDebuggingConnectionTests.loopback")
        let (listener, acceptedTransports, port) = try await makeListener(queue: queue)
        defer { listener.cancel() }
        let serverIdentity = try makeAuthenticationIdentity().pairingIdentity().material

        async let serverResult = runServer(
            acceptedTransports: acceptedTransports,
            identity: serverIdentity
        )
        var connection = try await ADBDeviceConnection.connectedToWirelessDebugging(
            target: .hostPort(ADBNetworkEndpoint(host: "127.0.0.1", port: port)),
            authenticationIdentity: makeAuthenticationIdentity(),
            queue: queue
        )
        defer { connection.cancel() }

        let connectedDevice = try await connection.connect()
        XCTAssertEqual(connectedDevice.banner, "device::ro.product.model=Loopback TV")

        let output = try await connection.runShellCommand(
            try ADBShellCommand("getprop ro.product.model")
        )
        let observedPackets = try await serverResult

        XCTAssertEqual(output.utf8String, "Loopback TV\n")
        XCTAssertEqual(observedPackets.connect.command, .connect)
        XCTAssertEqual(observedPackets.secureTLS, ADBPacket(
            command: .secureTLS,
            arg0: ADBConnectionState.secureTLSVersion,
            arg1: 0
        ))
        XCTAssertEqual(
            ADBPayload.stringFromNullTerminatedUTF8(observedPackets.open.payload),
            "shell:getprop ro.product.model"
        )
    }

    func testLoopbackLegacyAuthenticationConnectionRunsShellCommand() async throws {
        let queue = DispatchQueue(label: "ADBWirelessDebuggingConnectionTests.legacyAuthentication")
        let (listener, acceptedTransports, port) = try await makeListener(queue: queue)
        defer { listener.cancel() }

        async let serverResult = runLegacyAuthenticationServer(
            acceptedTransports: acceptedTransports
        )
        var connection = try await ADBDeviceConnection.connectedToWirelessDebugging(
            target: .hostPort(ADBNetworkEndpoint(host: "127.0.0.1", port: port)),
            authenticationIdentity: makeAuthenticationIdentity(),
            queue: queue
        )
        defer { connection.cancel() }

        let connectedDevice = try await connection.connect()
        XCTAssertEqual(connectedDevice.banner, "device::ro.product.model=Legacy TV")
        let output = try await connection.runShellCommand(
            try ADBShellCommand("getprop ro.product.model")
        )
        let observed = try await serverResult

        XCTAssertEqual(output.utf8String, "Legacy TV\n")
        XCTAssertEqual(observed.signature.command, .auth)
        XCTAssertEqual(observed.signature.arg0, ADBAuthenticationType.signature.rawValue)
        XCTAssertEqual(observed.signature.payload.count, 256)
        XCTAssertEqual(observed.publicKey.command, .auth)
        XCTAssertEqual(observed.publicKey.arg0, ADBAuthenticationType.rsaPublicKey.rawValue)
        XCTAssertEqual(observed.publicKey.payload.last, 0)
        XCTAssertFalse(
            ADBPayload.stringFromNullTerminatedUTF8(observed.publicKey.payload).isEmpty
        )
        XCTAssertEqual(
            observed.openService,
            "shell:getprop ro.product.model"
        )
    }

    func testLoopbackSTARTTLSConnectionInstallsAPK() async throws {
        let queue = DispatchQueue(label: "ADBWirelessDebuggingConnectionTests.installLoopback")
        let (listener, acceptedTransports, port) = try await makeListener(queue: queue)
        defer { listener.cancel() }

        let contents = makeTestAPK()
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "Loopback App.apk",
            byteCount: Int64(contents.count)
        )
        let serverIdentity = try makeAuthenticationIdentity().pairingIdentity().material
        async let serverResult = runInstallServer(
            acceptedTransports: acceptedTransports,
            identity: serverIdentity,
            contents: contents,
            plan: plan
        )
        var connection = try await ADBDeviceConnection.connectedToWirelessDebugging(
            target: .hostPort(ADBNetworkEndpoint(host: "127.0.0.1", port: port)),
            authenticationIdentity: makeAuthenticationIdentity(),
            queue: queue
        )
        defer { connection.cancel() }

        let eventRecorder = APKInstallIntegrationEventRecorder()
        let report = try await connection.installAPK(
            contents: contents,
            plan: plan,
            modificationTime: 123,
            eventHandler: { event in
                await eventRecorder.record(event)
            }
        )
        let observed = try await serverResult
        let streamedEvents = await eventRecorder.recordedEvents()

        XCTAssertEqual(report.result, .success)
        XCTAssertEqual(streamedEvents, report.events)
        XCTAssertEqual(observed.prepareCommand, try plan.prepareRemoteDirectoryShellCommand().rawValue)
        XCTAssertEqual(observed.syncService, "sync:")
        XCTAssertEqual(observed.syncBytes, try ADBSyncPushPlan(
            remotePath: plan.remoteAPKPath,
            modificationTime: 123,
            totalByteCount: contents.count
        ).encode(contents: contents).encodedBytes())
        XCTAssertEqual(observed.installCommand, try plan.installShellCommand().rawValue)
        XCTAssertEqual(observed.cleanupCommand, try plan.cleanupShellCommand().rawValue)
    }

    private func runServer(
        acceptedTransports: AsyncStream<ADBNetworkTransport>,
        identity: ADBPairingIdentityMaterial
    ) async throws -> ObservedPackets {
        let secureConnection = try await acceptSecureConnection(
            acceptedTransports: acceptedTransports,
            identity: identity
        )
        defer { secureConnection.networkTransport.cancel() }

        let openFrame = try await receiveFrame(from: secureConnection.tlsTransport)
        guard openFrame.packet.command == .open else {
            throw LoopbackServerError.unexpectedPacket(openFrame.packet.command)
        }
        let localID = openFrame.packet.arg0
        let remoteID: UInt32 = 42
        let response = try ADBPacket(
            command: .okay,
            arg0: remoteID,
            arg1: localID
        ).encoded() + ADBPacket(
            command: .write,
            arg0: remoteID,
            arg1: localID,
            payload: Array("Loopback TV\n".utf8)
        ).encoded() + ADBPacket(
            command: .close,
            arg0: remoteID,
            arg1: localID
        ).encoded()
        try await secureConnection.tlsTransport.send(response)
        let acknowledgement = try await receiveFrame(from: secureConnection.tlsTransport)
        guard acknowledgement.packet.command == .okay else {
            throw LoopbackServerError.unexpectedPacket(acknowledgement.packet.command)
        }

        return ObservedPackets(
            connect: secureConnection.connect,
            secureTLS: secureConnection.secureTLS,
            open: openFrame.packet
        )
    }

    private func runLegacyAuthenticationServer(
        acceptedTransports: AsyncStream<ADBNetworkTransport>
    ) async throws -> ObservedLegacyAuthentication {
        var iterator = acceptedTransports.makeAsyncIterator()
        guard let transport = await iterator.next() else {
            throw LoopbackServerError.connectionNotAccepted
        }
        defer { transport.cancel() }

        var reader = LoopbackPacketReader(transport: transport)
        let connect = try await reader.next()
        try require(connect.command == .connect, packet: connect)

        try await transport.send(try ADBPacket(
            command: .auth,
            arg0: ADBAuthenticationType.token.rawValue,
            arg1: 0,
            payload: [UInt8](repeating: 0x41, count: 20)
        ).encoded())
        let signature = try await reader.next()
        try require(
            signature.command == .auth
                && signature.arg0 == ADBAuthenticationType.signature.rawValue,
            packet: signature
        )

        try await transport.send(try ADBPacket(
            command: .auth,
            arg0: ADBAuthenticationType.token.rawValue,
            arg1: 0,
            payload: [UInt8](repeating: 0x42, count: 20)
        ).encoded())
        let publicKey = try await reader.next()
        try require(
            publicKey.command == .auth
                && publicKey.arg0 == ADBAuthenticationType.rsaPublicKey.rawValue,
            packet: publicKey
        )

        try await transport.send(try ADBPacket(
            command: .connect,
            arg0: ADBConnectionState.defaultProtocolVersion,
            arg1: ADBConnectionState.defaultMaxData,
            payload: ADBPayload.nullTerminatedUTF8("device::ro.product.model=Legacy TV")
        ).encoded())
        let open = try await serveShellCommand(
            reader: &reader,
            transport: transport,
            output: Array("Legacy TV\n".utf8)
        )

        return ObservedLegacyAuthentication(
            connect: connect,
            signature: signature,
            publicKey: publicKey,
            openService: "shell:\(open)"
        )
    }

    private func runInstallServer(
        acceptedTransports: AsyncStream<ADBNetworkTransport>,
        identity: ADBPairingIdentityMaterial,
        contents: [UInt8],
        plan: ADBAPKInstallPlan
    ) async throws -> ObservedInstall {
        let secureConnection = try await acceptSecureConnection(
            acceptedTransports: acceptedTransports,
            identity: identity
        )
        defer { secureConnection.networkTransport.cancel() }

        var reader = LoopbackPacketReader(transport: secureConnection.tlsTransport)
        let prepareCommand = try await serveShellCommand(
            reader: &reader,
            transport: secureConnection.tlsTransport,
            output: []
        )
        let syncObservation = try await serveSyncPush(
            reader: &reader,
            transport: secureConnection.tlsTransport,
            contents: contents,
            plan: try ADBSyncPushPlan(
                remotePath: plan.remoteAPKPath,
                modificationTime: 123,
                totalByteCount: contents.count
            )
        )
        let installCommand = try await serveShellCommand(
            reader: &reader,
            transport: secureConnection.tlsTransport,
            output: Array("Success\n".utf8)
        )
        let cleanupCommand = try await serveShellCommand(
            reader: &reader,
            transport: secureConnection.tlsTransport,
            output: []
        )

        return ObservedInstall(
            prepareCommand: prepareCommand,
            syncService: syncObservation.service,
            syncBytes: syncObservation.bytes,
            installCommand: installCommand,
            cleanupCommand: cleanupCommand
        )
    }

    private func acceptSecureConnection(
        acceptedTransports: AsyncStream<ADBNetworkTransport>,
        identity: ADBPairingIdentityMaterial
    ) async throws -> SecureLoopbackConnection {
        var iterator = acceptedTransports.makeAsyncIterator()
        guard let networkTransport = await iterator.next() else {
            throw LoopbackServerError.connectionNotAccepted
        }

        let connectFrame = try await receiveFrame(from: networkTransport)
        guard connectFrame.packet.command == .connect else {
            throw LoopbackServerError.unexpectedPacket(connectFrame.packet.command)
        }
        try await networkTransport.send(try ADBPacket(
            command: .secureTLS,
            arg0: ADBConnectionState.secureTLSVersion,
            arg1: 0
        ).encoded())

        let secureTLSFrame = try await receiveFrame(
            from: networkTransport,
            initialBytes: connectFrame.trailingBytes
        )
        guard secureTLSFrame.packet.command == .secureTLS else {
            throw LoopbackServerError.unexpectedPacket(secureTLSFrame.packet.command)
        }

        let tlsTransport = try await ADBTLSByteTransport.upgrade(
            underlying: networkTransport,
            identity: identity,
            role: .server,
            initialEncryptedInput: secureTLSFrame.trailingBytes
        )
        try await tlsTransport.send(try ADBPacket(
            command: .connect,
            arg0: ADBConnectionState.defaultProtocolVersion,
            arg1: ADBConnectionState.defaultMaxData,
            payload: ADBPayload.nullTerminatedUTF8("device::ro.product.model=Loopback TV")
        ).encoded())

        return SecureLoopbackConnection(
            networkTransport: networkTransport,
            tlsTransport: tlsTransport,
            connect: connectFrame.packet,
            secureTLS: secureTLSFrame.packet
        )
    }

    private func serveShellCommand(
        reader: inout LoopbackPacketReader,
        transport: any ADBByteTransport,
        output: [UInt8]
    ) async throws -> String {
        let open = try await reader.next()
        try require(open.command == .open, packet: open)
        let service = ADBPayload.stringFromNullTerminatedUTF8(open.payload)
        guard service.hasPrefix("shell:") else {
            throw LoopbackServerError.unexpectedService(service)
        }

        let localID = open.arg0
        let remoteID = localID + 100
        var response = try ADBPacket(
            command: .okay,
            arg0: remoteID,
            arg1: localID
        ).encoded()
        if !output.isEmpty {
            response.append(contentsOf: try ADBPacket(
                command: .write,
                arg0: remoteID,
                arg1: localID,
                payload: output
            ).encoded())
        }
        response.append(contentsOf: try ADBPacket(
            command: .close,
            arg0: remoteID,
            arg1: localID
        ).encoded())
        try await transport.send(response)

        if !output.isEmpty {
            let acknowledgement = try await reader.next()
            try require(
                acknowledgement.command == .okay
                    && acknowledgement.arg0 == localID
                    && acknowledgement.arg1 == remoteID,
                packet: acknowledgement
            )
        }

        return String(service.dropFirst("shell:".count))
    }

    private func serveSyncPush(
        reader: inout LoopbackPacketReader,
        transport: ADBTLSByteTransport,
        contents: [UInt8],
        plan: ADBSyncPushPlan
    ) async throws -> ObservedSyncPush {
        let open = try await reader.next()
        try require(open.command == .open, packet: open)
        let service = ADBPayload.stringFromNullTerminatedUTF8(open.payload)
        guard service == "sync:" else {
            throw LoopbackServerError.unexpectedService(service)
        }

        let localID = open.arg0
        let remoteID = localID + 100
        try await transport.send(try ADBPacket(
            command: .okay,
            arg0: remoteID,
            arg1: localID
        ).encoded())

        let expectedBytes = try plan.encode(contents: contents).encodedBytes()
        var receivedBytes: [UInt8] = []
        while receivedBytes.count < expectedBytes.count {
            let write = try await reader.next()
            try require(
                write.command == .write && write.arg0 == localID && write.arg1 == remoteID,
                packet: write
            )
            receivedBytes.append(contentsOf: write.payload)
            guard receivedBytes.count <= expectedBytes.count,
                  receivedBytes == Array(expectedBytes.prefix(receivedBytes.count)) else {
                throw LoopbackServerError.unexpectedPayload
            }
            var acknowledgement = try ADBPacket(
                command: .okay,
                arg0: remoteID,
                arg1: localID
            ).encoded()
            if receivedBytes.count == expectedBytes.count {
                acknowledgement.append(contentsOf: try ADBPacket(
                    command: .write,
                    arg0: remoteID,
                    arg1: localID,
                    payload: ADBSyncFrame(id: .okay, value: 0).encoded()
                ).encoded())
            }
            try await transport.send(acknowledgement)
        }

        let responseAcknowledgement = try await reader.next()
        try require(
            responseAcknowledgement.command == .okay
                && responseAcknowledgement.arg0 == localID
                && responseAcknowledgement.arg1 == remoteID,
            packet: responseAcknowledgement
        )

        let quit = try await reader.next()
        try require(
            quit.command == .write && quit.arg0 == localID && quit.arg1 == remoteID,
            packet: quit
        )
        guard quit.payload == (try ADBSyncFrame.quit().encoded()) else {
            throw LoopbackServerError.unexpectedPayload
        }
        try await transport.send(try ADBPacket(
            command: .okay,
            arg0: remoteID,
            arg1: localID
        ).encoded())

        let close = try await reader.next()
        try require(
            close.command == .close && close.arg0 == localID && close.arg1 == remoteID,
            packet: close
        )
        return ObservedSyncPush(service: service, bytes: receivedBytes)
    }

    private func require(_ condition: Bool, packet: ADBPacket) throws {
        guard condition else {
            throw LoopbackServerError.unexpectedPacket(packet.command)
        }
    }

    private func makeListener(
        queue: DispatchQueue
    ) async throws -> (NWListener, AsyncStream<ADBNetworkTransport>, UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        let acceptedTransports = AsyncStream<ADBNetworkTransport> { continuation in
            listener.newConnectionHandler = { connection in
                let transport = ADBNetworkTransport(connection: connection, queue: queue)
                transport.start()
                continuation.yield(transport)
                continuation.finish()
            }
        }
        try await start(listener: listener, queue: queue)
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw LoopbackServerError.listenerMissingPort
        }
        return (listener, acceptedTransports, port)
    }

    private func receiveFrame(
        from transport: any ADBByteTransport,
        initialBytes: [UInt8] = []
    ) async throws -> ReceivedFrame {
        var bytes = initialBytes
        while true {
            do {
                let frame = try ADBPacket.decodeFrame(from: bytes)
                return ReceivedFrame(
                    packet: frame.packet,
                    trailingBytes: Array(bytes.dropFirst(frame.consumedByteCount))
                )
            } catch let error as ADBPacketFramingError {
                switch error {
                case .incompleteHeader, .incompletePayload:
                    guard let received = try await transport.receive() else {
                        throw LoopbackServerError.transportClosed
                    }
                    bytes.append(contentsOf: received)
                default:
                    throw error
                }
            }
        }
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

private struct ReceivedFrame: Sendable {
    var packet: ADBPacket
    var trailingBytes: [UInt8]
}

private struct ObservedPackets: Sendable {
    var connect: ADBPacket
    var secureTLS: ADBPacket
    var open: ADBPacket
}

private struct ObservedInstall: Sendable {
    var prepareCommand: String
    var syncService: String
    var syncBytes: [UInt8]
    var installCommand: String
    var cleanupCommand: String
}

private struct ObservedLegacyAuthentication: Sendable {
    var connect: ADBPacket
    var signature: ADBPacket
    var publicKey: ADBPacket
    var openService: String
}

private struct ObservedSyncPush: Sendable {
    var service: String
    var bytes: [UInt8]
}

private struct SecureLoopbackConnection: Sendable {
    var networkTransport: ADBNetworkTransport
    var tlsTransport: ADBTLSByteTransport
    var connect: ADBPacket
    var secureTLS: ADBPacket
}

private struct LoopbackPacketReader: Sendable {
    private let transport: any ADBByteTransport
    private var bufferedBytes: [UInt8]

    init(transport: any ADBByteTransport, bufferedBytes: [UInt8] = []) {
        self.transport = transport
        self.bufferedBytes = bufferedBytes
    }

    mutating func next() async throws -> ADBPacket {
        while true {
            do {
                let frame = try ADBPacket.decodeFrame(from: bufferedBytes)
                bufferedBytes.removeFirst(frame.consumedByteCount)
                return frame.packet
            } catch let error as ADBPacketFramingError {
                switch error {
                case .incompleteHeader, .incompletePayload:
                    guard let received = try await transport.receive() else {
                        throw LoopbackServerError.transportClosed
                    }
                    bufferedBytes.append(contentsOf: received)
                default:
                    throw error
                }
            }
        }
    }
}

private actor APKInstallIntegrationEventRecorder {
    private var events: [ADBAPKInstallEvent] = []

    func record(_ event: ADBAPKInstallEvent) {
        events.append(event)
    }

    func recordedEvents() -> [ADBAPKInstallEvent] {
        events
    }
}

private enum LoopbackServerError: Error {
    case connectionNotAccepted
    case listenerMissingPort
    case unexpectedPacket(ADBCommand)
    case unexpectedPayload
    case unexpectedService(String)
    case transportClosed
}
#endif
