import ADBClientCore
import Foundation

#if canImport(Network)
public struct ADBTVPairingOperation: Sendable {
    public typealias Pair = @Sendable (
        ADBNetworkTarget,
        ADBPairingSecret
    ) async throws -> ADBPairingPeerInfo

    private let pair: Pair

    public init() {
        self.pair = { target, secret in
            try await Self.pairUsingSystemClient(target: target, secret: secret)
        }
    }

    public init(pair: @escaping Pair) {
        self.pair = pair
    }

    public func pairManualCode(from draft: ADBTVPairingDraft) async throws -> ADBTVDeviceSummary {
        guard !draft.normalizedHost.isEmpty else {
            throw ADBTVPairingOperationError.missingHost
        }
        guard let pairingPort = draft.pairingPort else {
            throw ADBTVPairingOperationError.invalidPairingPort
        }
        guard let connectionPort = draft.connectionPort else {
            throw ADBTVPairingOperationError.invalidConnectionPort
        }
        guard let pairingCode = draft.pairingCode else {
            throw ADBTVPairingOperationError.invalidPairingCode
        }

        let endpoint = ADBNetworkEndpoint(host: draft.normalizedHost, port: pairingPort)
        let secret = try ADBPairingSecret(code: pairingCode)
        _ = try await pair(.hostPort(endpoint), secret)

        return ADBTVDeviceSummary(
            displayName: draft.normalizedDisplayName,
            host: draft.normalizedHost,
            port: Int(connectionPort),
            model: "Android TV"
        )
    }

    public func pairDiscoveredService(from draft: ADBTVPairingDraft) async throws -> String {
        guard let service = draft.discoveredService, service.kind == .pairing else {
            throw ADBTVPairingOperationError.invalidDiscoveredService
        }
        guard let pairingCode = draft.pairingCode else {
            throw ADBTVPairingOperationError.invalidPairingCode
        }

        let secret = try ADBPairingSecret(code: pairingCode)
        let peerInfo = try await pair(.bonjourService(service), secret)
        guard let deviceGUID = peerInfo.deviceGUID else {
            throw ADBTVPairingOperationError.missingDeviceGUID
        }

        return deviceGUID
    }

    public func pairQRCode(from draft: ADBTVPairingDraft) async throws -> String {
        guard let qrCode = draft.pairingQRCode else {
            throw ADBTVPairingOperationError.invalidPairingQRCode
        }
        guard let service = draft.discoveredService,
              service.kind == .pairing,
              service.serviceName == qrCode.serviceName else {
            throw ADBTVPairingOperationError.mismatchedQRCodeService
        }

        let secret = try ADBPairingSecret(qrCode: qrCode)
        let peerInfo = try await pair(.bonjourService(service), secret)
        guard let deviceGUID = peerInfo.deviceGUID else {
            throw ADBTVPairingOperationError.missingDeviceGUID
        }

        return deviceGUID
    }

    private static func pairUsingSystemClient(
        target: ADBNetworkTarget,
        secret: ADBPairingSecret
    ) async throws -> ADBPairingPeerInfo {
#if canImport(CryptoKit) && canImport(Security)
        try await ADBWirelessPairingClient().pair(target: target, secret: secret)
#else
        throw ADBTVPairingOperationError.unsupportedPlatform
#endif
    }
}

public enum ADBTVPairingOperationError: Error, Equatable, Sendable {
    case missingHost
    case invalidPairingPort
    case invalidConnectionPort
    case invalidPairingCode
    case invalidPairingQRCode
    case invalidDiscoveredService
    case mismatchedQRCodeService
    case missingDeviceGUID
    case unsupportedPlatform
}
#endif
