import ADBClientCore
import XCTest
@testable import ADBTVApp

#if canImport(Network)
final class ADBTVPairingOperationTests: XCTestCase {
    func testManualPairingUsesPairingEndpointAndBuildsSavedConnectionTarget() async throws {
        let recorder = PairingCallRecorder()
        let operation = ADBTVPairingOperation { endpoint, secret in
            await recorder.record(endpoint: endpoint, secret: secret)
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

        XCTAssertEqual(call.endpoint, ADBNetworkEndpoint(host: "192.168.1.50", port: 37123))
        XCTAssertEqual(call.secret.source, .code)
        XCTAssertEqual(call.secret.bytes, Array("123456".utf8))
        XCTAssertEqual(device.displayName, "Living Room TV")
        XCTAssertEqual(device.host, "192.168.1.50")
        XCTAssertEqual(device.port, 39555)
        XCTAssertEqual(device.model, "Android TV")
    }

    func testManualPairingRejectsIncompleteDraftBeforeCallingClient() async {
        let recorder = PairingCallRecorder()
        let operation = ADBTVPairingOperation { endpoint, secret in
            await recorder.record(endpoint: endpoint, secret: secret)
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

    private func assertThrows(
        _ expectedError: ADBTVPairingOperationError,
        operation: () async throws -> ADBTVDeviceSummary,
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

    func record(endpoint: ADBNetworkEndpoint, secret: ADBPairingSecret) {
        call = PairingCall(endpoint: endpoint, secret: secret)
    }
}

private struct PairingCall: Sendable {
    var endpoint: ADBNetworkEndpoint
    var secret: ADBPairingSecret
}
#endif
