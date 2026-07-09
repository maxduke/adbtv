import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVInstallOperationTests: XCTestCase {
    func testInstallSelectedPackageReadsFileAndCallsConnection() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/app.apk")
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        let model = ADBTVAppModel(
            devices: [device],
            installDraft: ADBTVInstallDraft(
                selectedPackage: ADBTVInstallPackageDraft(fileURL: fileURL, byteCount: 3)
            )
        )
        var connection = RecordingInstallConnection(result: .success)
        let operation = ADBTVInstallOperation(
            readFile: { url in
                XCTAssertEqual(url, fileURL)
                return [1, 2, 3]
            },
            modificationTime: { 123 }
        )

        let report = try await operation.installSelectedPackage(from: model, using: &connection)

        XCTAssertEqual(report.result, .success)
        XCTAssertEqual(connection.installedContents, [[1, 2, 3]])
        XCTAssertEqual(connection.installedPlans.map(\.remoteAPKPath.rawValue), [
            "/data/local/tmp/adbtv/app.apk"
        ])
        XCTAssertEqual(connection.modificationTimes, [123])
    }

    func testInstallSelectedPackageRejectsMissingDevicePackageAndFileURL() async throws {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var connection = RecordingInstallConnection(result: .success)

        await XCTAssertThrowsADBTVInstallOperationError({
            try await ADBTVInstallOperation().installSelectedPackage(
                from: ADBTVAppModel(),
                using: &connection
            )
        },
            .missingDevice
        )

        await XCTAssertThrowsADBTVInstallOperationError({
            try await ADBTVInstallOperation().installSelectedPackage(
                from: ADBTVAppModel(devices: [device]),
                using: &connection
            )
        },
            .missingPackage
        )

        await XCTAssertThrowsADBTVInstallOperationError({
            try await ADBTVInstallOperation().installSelectedPackage(
                from: ADBTVAppModel(
                    devices: [device],
                    installDraft: ADBTVInstallDraft(
                        selectedPackage: ADBTVInstallPackageDraft(fileName: "app.apk", byteCount: 1)
                    )
                ),
                using: &connection
            )
        },
            .missingPackageFile
        )
    }
}

private struct RecordingInstallConnection: ADBTVAPKInstallConnection {
    var result: ADBAPKInstallResult
    private(set) var installedContents: [[UInt8]]
    private(set) var installedPlans: [ADBAPKInstallPlan]
    private(set) var modificationTimes: [UInt32]

    init(result: ADBAPKInstallResult) {
        self.result = result
        self.installedContents = []
        self.installedPlans = []
        self.modificationTimes = []
    }

    mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32
    ) async throws -> ADBAPKInstallReport {
        installedContents.append(contents)
        installedPlans.append(plan)
        modificationTimes.append(modificationTime)
        return ADBAPKInstallReport(plan: plan, result: result, events: [
            .installResult(result)
        ])
    }
}

private func XCTAssertThrowsADBTVInstallOperationError<T>(
    _ expression: () async throws -> T,
    _ expectedError: ADBTVInstallOperationError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expectedError) to be thrown.", file: file, line: line)
    } catch let error as ADBTVInstallOperationError {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("Expected \(expectedError), got \(error).", file: file, line: line)
    }
}
