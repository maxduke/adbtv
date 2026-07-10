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
        let eventRecorder = InstallOperationEventRecorder()

        let report = try await operation.installSelectedPackage(
            from: model,
            using: &connection,
            eventHandler: { event in
                await eventRecorder.record(event)
            }
        )
        let streamedEvents = await eventRecorder.recordedEvents()

        XCTAssertEqual(report.result, .success)
        XCTAssertEqual(connection.installedContents, [[1, 2, 3]])
        XCTAssertEqual(connection.installedPlans.map(\.remoteAPKPath.rawValue), [
            "/data/local/tmp/adbtv/app.apk"
        ])
        XCTAssertEqual(connection.modificationTimes, [123])
        XCTAssertEqual(streamedEvents, [.installResult(.success)])
    }

    func testInstallSelectedPackageDownloadsURLAndCallsConnection() async throws {
        let url = URL(string: "https://example.com/Remote%20App.apk")!
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        let model = ADBTVAppModel(
            devices: [device],
            installDraft: ADBTVInstallDraft(urlString: url.absoluteString)
        )
        var connection = RecordingInstallConnection(result: .success)
        let operation = ADBTVInstallOperation(
            readFile: { _ in
                XCTFail("URL installs should not read a local file.")
                return []
            },
            downloadPackage: { downloadURL in
                XCTAssertEqual(downloadURL, url)
                return ADBTVDownloadedPackage(contents: [9, 8, 7], fileName: "Remote App.apk")
            },
            modificationTime: { 456 }
        )

        let report = try await operation.installSelectedPackage(from: model, using: &connection)

        XCTAssertEqual(report.result, .success)
        XCTAssertEqual(connection.installedContents, [[9, 8, 7]])
        XCTAssertEqual(connection.installedPlans.map(\.remoteAPKPath.rawValue), [
            "/data/local/tmp/adbtv/Remote_App.apk"
        ])
        XCTAssertEqual(connection.installedPlans.map(\.package.byteCount), [Optional(Int64(3))])
        XCTAssertEqual(connection.modificationTimes, [456])
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
        modificationTime: UInt32,
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async throws -> ADBAPKInstallReport {
        installedContents.append(contents)
        installedPlans.append(plan)
        modificationTimes.append(modificationTime)
        let event = ADBAPKInstallEvent.installResult(result)
        await eventHandler(event)
        return ADBAPKInstallReport(plan: plan, result: result, events: [event])
    }
}

private actor InstallOperationEventRecorder {
    private var events: [ADBAPKInstallEvent] = []

    func record(_ event: ADBAPKInstallEvent) {
        events.append(event)
    }

    func recordedEvents() -> [ADBAPKInstallEvent] {
        events
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
