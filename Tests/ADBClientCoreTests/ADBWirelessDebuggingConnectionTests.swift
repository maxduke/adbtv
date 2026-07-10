#if canImport(Network) && canImport(Security)
@testable import ADBClientCore
import Dispatch
import Network
import Security
import XCTest

final class ADBWirelessDebuggingConnectionTests: XCTestCase {
    func testLoopbackSTARTTLSConnectionRunsShellCommand() async throws {
        let queue = DispatchQueue(label: "ADBWirelessDebuggingConnectionTests.loopback")
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

    private func runServer(
        acceptedTransports: AsyncStream<ADBNetworkTransport>,
        identity: ADBPairingIdentityMaterial
    ) async throws -> ObservedPackets {
        var iterator = acceptedTransports.makeAsyncIterator()
        guard let networkTransport = await iterator.next() else {
            throw LoopbackServerError.connectionNotAccepted
        }
        defer { networkTransport.cancel() }

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

        let openFrame = try await receiveFrame(from: tlsTransport)
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
        try await tlsTransport.send(response)
        let acknowledgement = try await receiveFrame(from: tlsTransport)
        guard acknowledgement.packet.command == .okay else {
            throw LoopbackServerError.unexpectedPacket(acknowledgement.packet.command)
        }

        return ObservedPackets(
            connect: connectFrame.packet,
            secureTLS: secureTLSFrame.packet,
            open: openFrame.packet
        )
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

private enum LoopbackServerError: Error {
    case connectionNotAccepted
    case unexpectedPacket(ADBCommand)
    case transportClosed
}
#endif
