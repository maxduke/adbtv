import ADBClientCore
import XCTest
@testable import ADBTVApp

#if canImport(Network)
final class ADBTVPairingOperationTests: XCTestCase {
    func testManualPairingUsesPairingEndpointAndBuildsSavedConnectionTarget() async throws {
        let recorder = PairingCallRecorder()
        let operation = ADBTVPairingOperation { target, secret in
            await recorder.record(target: target, secret: secret)
            return try ADBPairingPeerInfo(type: .adbDeviceGUID, data: Array("device-guid".utf8))
        }
        let draft = ADBTVPairingDraft(
            displayName: " Living Room TV ",
            host: " 192.168.1.50 ",
            pairingPortString: "37123",
            connectionPortString: "39555",
            codeString: "123 456"
        )

        let device = try await operation.pairManualCode(from: draft)
        let recordedCall = await recorder.call
        let call = try XCTUnwrap(recordedCall)

        XCTAssertEqual(
            call.target,
            .hostPort(ADBNetworkEndpoint(host: "192.168.1.50", port: 37123))
        )
        XCTAssertEqual(call.secret.source, .code)
        XCTAssertEqual(call.secret.bytes, Array("123456".utf8))
        XCTAssertEqual(device.displayName, "Living Room TV")
        XCTAssertEqual(device.host, "192.168.1.50")
        XCTAssertEqual(device.port, 39555)
        XCTAssertEqual(device.model, "Android TV")
    }

    func testManualPairingRejectsIncompleteDraftBeforeCallingClient() async {
        let recorder = PairingCallRecorder()
        let operation = ADBTVPairingOperation { target, secret in
            await recorder.record(target: target, secret: secret)
            return try ADBPairingPeerInfo(type: .adbDeviceGUID, data: [])
        }

        await assertThrows(.missingHost) {
            try await operation.pairManualCode(from: ADBTVPairingDraft(
                pairingPortString: "37123",
                connectionPortString: "39555",
                codeString: "123456"
            ))
        }
        await assertThrows(.invalidPairingPort) {
            try await operation.pairManualCode(from: ADBTVPairingDraft(
                host: "tv.local",
                pairingPortString: "70000",
                connectionPortString: "39555",
                codeString: "123456"
            ))
        }
        await assertThrows(.invalidConnectionPort) {
            try await operation.pairManualCode(from: ADBTVPairingDraft(
                host: "tv.local",
                pairingPortString: "37123",
                codeString: "123456"
            ))
        }
        await assertThrows(.invalidPairingCode) {
            try await operation.pairManualCode(from: ADBTVPairingDraft(
                host: "tv.local",
                pairingPortString: "37123",
                connectionPortString: "39555",
                codeString: "12345"
            ))
        }

        let recordedCall = await recorder.call
        XCTAssertNil(recordedCall)
    }

    func testDiscoveredPairingUsesBonjourTargetAndReturnsDeviceGUID() async throws {
        let service = ADBDiscoveredService(
            serviceName: "pairing-service",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        let recorder = PairingCallRecorder()
        let operation = ADBTVPairingOperation { target, secret in
            await recorder.record(target: target, secret: secret)
            return try ADBPairingPeerInfo(
                type: .adbDeviceGUID,
                data: Array("adb-device-guid".utf8)
            )
        }
        let draft = ADBTVPairingDraft(
            codeString: "123456",
            discoveredService: service
        )

        let deviceGUID = try await operation.pairDiscoveredService(from: draft)
        let recordedCall = await recorder.call
        let call = try XCTUnwrap(recordedCall)

        XCTAssertEqual(deviceGUID, "adb-device-guid")
        XCTAssertEqual(call.target, .bonjourService(service))
        XCTAssertEqual(call.secret.bytes, Array("123456".utf8))
    }

    func testDiscoveredPairingRequiresPairingServiceCodeAndDeviceGUID() async {
        let connectService = ADBDiscoveredService(
            serviceName: "connect-service",
            serviceType: ADBWirelessDebuggingServiceKind.connect.bonjourType,
            domain: "local."
        )
        let operation = ADBTVPairingOperation { _, _ in
            try ADBPairingPeerInfo(type: .adbRSAPublicKey, data: [1])
        }

        await assertThrows(.invalidDiscoveredService) {
            try await operation.pairDiscoveredService(from: ADBTVPairingDraft(
                codeString: "123456",
                discoveredService: connectService
            ))
        }
        await assertThrows(.invalidPairingCode) {
            try await operation.pairDiscoveredService(from: ADBTVPairingDraft(
                codeString: "12345",
                discoveredService: ADBDiscoveredService(
                    serviceName: "pairing-service",
                    serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
                    domain: "local."
                )
            ))
        }
        await assertThrows(.missingDeviceGUID) {
            try await operation.pairDiscoveredService(from: ADBTVPairingDraft(
                codeString: "123456",
                discoveredService: ADBDiscoveredService(
                    serviceName: "pairing-service",
                    serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
                    domain: "local."
                )
            ))
        }
    }

    func testQRCodePairingUsesMatchingBonjourServiceAndQRSecret() async throws {
        let service = ADBDiscoveredService(
            serviceName: "adb-qr-service",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        let recorder = PairingCallRecorder()
        let operation = ADBTVPairingOperation { target, secret in
            await recorder.record(target: target, secret: secret)
            return try ADBPairingPeerInfo(
                type: .adbDeviceGUID,
                data: Array("adb-device-guid".utf8)
            )
        }
        let draft = ADBTVPairingDraft(
            qrPayload: "WIFI:T:ADB;S:adb-qr-service;P:qr-secret;;",
            discoveredService: service
        )

        let deviceGUID = try await operation.pairQRCode(from: draft)
        let recordedCall = await recorder.call
        let call = try XCTUnwrap(recordedCall)

        XCTAssertEqual(deviceGUID, "adb-device-guid")
        XCTAssertEqual(call.target, .bonjourService(service))
        XCTAssertEqual(call.secret.source, .qrCode(serviceName: "adb-qr-service"))
        XCTAssertEqual(call.secret.bytes, Array("qr-secret".utf8))
    }

    func testQRCodePairingRejectsInvalidAndMismatchedDrafts() async {
        let operation = ADBTVPairingOperation { _, _ in
            try ADBPairingPeerInfo(type: .adbDeviceGUID, data: Array("guid".utf8))
        }

        await assertThrows(.invalidPairingQRCode) {
            try await operation.pairQRCode(from: ADBTVPairingDraft(qrPayload: "invalid"))
        }
        await assertThrows(.mismatchedQRCodeService) {
            try await operation.pairQRCode(from: ADBTVPairingDraft(
                qrPayload: "WIFI:T:ADB;S:expected-service;P:qr-secret;;",
                discoveredService: ADBDiscoveredService(
                    serviceName: "other-service",
                    serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
                    domain: "local."
                )
            ))
        }
    }

    private func assertThrows<T>(
        _ expectedError: ADBTVPairingOperationError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expectedError) to be thrown.", file: file, line: line)
        } catch let error as ADBTVPairingOperationError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Expected \(expectedError), got \(error).", file: file, line: line)
        }
    }
}

private actor PairingCallRecorder {
    private(set) var call: PairingCall?

    func record(target: ADBNetworkTarget, secret: ADBPairingSecret) {
        call = PairingCall(target: target, secret: secret)
    }
}

private struct PairingCall: Sendable {
    var target: ADBNetworkTarget
    var secret: ADBPairingSecret
}
#endif
