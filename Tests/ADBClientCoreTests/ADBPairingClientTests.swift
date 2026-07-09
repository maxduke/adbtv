import XCTest
@testable import ADBClientCore

final class ADBPairingClientTests: XCTestCase {
    func testPairingClientRunsProtocolOverChunkedTransport() async throws {
        let localPeerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [10, 11])
        let remotePeerInfo = try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [20, 21])
        let remoteSPAKE2Packet = try ADBPairingPacket(type: .spake2Message, payload: [4, 5, 6]).encoded()
        let remotePeerInfoPacket = try ADBPairingPacket(
            type: .peerInfo,
            payload: PairingClientTestCipher.encryptionPrefix + remotePeerInfo.encoded()
        ).encoded()
        let transport = PairingClientTestTransport(inboundChunks: [
            Array(remoteSPAKE2Packet.prefix(2)),
            Array(remoteSPAKE2Packet.dropFirst(2)) + Array(remotePeerInfoPacket.prefix(3)),
            Array(remotePeerInfoPacket.dropFirst(3))
        ])
        var client = ADBPairingClient(
            session: ADBPairingProtocolSession(
                localPeerInfo: localPeerInfo,
                keyExchange: PairingClientTestKeyExchange(
                    localMessage: [1, 2, 3],
                    expectedPeerMessage: [4, 5, 6],
                    cipher: PairingClientTestCipher()
                )
            ),
            transport: transport
        )

        let result = try await client.pair()
        let sentChunks = await transport.sentChunks()
        let sentPackets = try sentChunks.map { try ADBPairingPacket(encodedBytes: $0) }

        XCTAssertEqual(result, remotePeerInfo)
        XCTAssertEqual(sentPackets.map(\.header.type), [.spake2Message, .peerInfo])
        XCTAssertEqual(sentPackets[0].payload, [1, 2, 3])
        XCTAssertEqual(sentPackets[1].payload, PairingClientTestCipher.encryptionPrefix + localPeerInfo.encoded())
    }

    func testPairingClientThrowsWhenTransportClosesMidPacket() async throws {
        let headerOnly = try ADBPairingPacketHeader(type: .spake2Message, payloadSize: 3).encoded()
        let transport = PairingClientTestTransport(inboundChunks: [headerOnly])
        var client = ADBPairingClient(
            session: ADBPairingProtocolSession(
                localPeerInfo: try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [10, 11]),
                keyExchange: PairingClientTestKeyExchange(
                    localMessage: [1, 2, 3],
                    expectedPeerMessage: [4, 5, 6],
                    cipher: PairingClientTestCipher()
                )
            ),
            transport: transport
        )

        do {
            _ = try await client.pair()
            XCTFail("Expected pairing to throw when the transport closes mid-packet.")
        } catch let error as ADBPairingClientError {
            XCTAssertEqual(error, .transportClosed(expectedByteCount: 3, bufferedByteCount: 0))
        }
    }
}

private actor PairingClientTestTransport: ADBByteTransport {
    private var inboundChunks: [[UInt8]]
    private var outboundChunks: [[UInt8]]

    init(inboundChunks: [[UInt8]]) {
        self.inboundChunks = inboundChunks
        self.outboundChunks = []
    }

    func send(_ bytes: [UInt8]) async throws {
        outboundChunks.append(bytes)
    }

    func receive() async throws -> [UInt8]? {
        guard !inboundChunks.isEmpty else {
            return nil
        }

        return inboundChunks.removeFirst()
    }

    func sentChunks() -> [[UInt8]] {
        outboundChunks
    }
}

private struct PairingClientTestKeyExchange: ADBPairingKeyExchange {
    var localMessage: [UInt8]
    var expectedPeerMessage: [UInt8]
    var cipher: any ADBPairingCipher

    mutating func localSPAKE2Message() throws -> [UInt8] {
        localMessage
    }

    mutating func initializeCipher(peerSPAKE2Message: [UInt8]) throws -> any ADBPairingCipher {
        if peerSPAKE2Message != expectedPeerMessage {
            throw PairingClientTestKeyExchangeError.unexpectedPeerMessage(peerSPAKE2Message)
        }

        return cipher
    }
}

private enum PairingClientTestKeyExchangeError: Error, Equatable {
    case unexpectedPeerMessage([UInt8])
}

private struct PairingClientTestCipher: ADBPairingCipher {
    static let encryptionPrefix: [UInt8] = [0xEE]

    func encrypt(_ plaintext: [UInt8]) throws -> [UInt8] {
        Self.encryptionPrefix + plaintext
    }

    func decrypt(_ ciphertext: [UInt8]) throws -> [UInt8] {
        guard ciphertext.starts(with: Self.encryptionPrefix) else {
            throw PairingClientTestCipherError.missingPrefix
        }

        return Array(ciphertext.dropFirst(Self.encryptionPrefix.count))
    }
}

private enum PairingClientTestCipherError: Error, Equatable {
    case missingPrefix
}
