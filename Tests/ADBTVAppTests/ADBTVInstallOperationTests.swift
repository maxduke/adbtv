import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVInstallOperationTests: XCTestCase {
    func testInstallSelectedPackageReadsFileAndCallsConnection() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/app.apk")
        let contents = makeADBTVTestAPK()
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        let model = ADBTVAppModel(
            devices: [device],
            installDraft: ADBTVInstallDraft(
                selectedPackage: ADBTVInstallPackageDraft(
                    fileURL: fileURL,
                    byteCount: Int64(contents.count)
                )
            )
        )
        var connection = RecordingInstallConnection(result: .success)
        let operation = ADBTVInstallOperation(
            readFile: { url in
                XCTAssertEqual(url, fileURL)
                return contents
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
        XCTAssertEqual(connection.installedContents, [contents])
        let installedPath = try XCTUnwrap(connection.installedPlans.first?.remoteAPKPath.rawValue)
        XCTAssertTrue(installedPath.hasPrefix("/data/local/tmp/adbtv/"))
        XCTAssertTrue(installedPath.hasSuffix(".apk"))
        XCTAssertEqual(connection.modificationTimes, [123])
        XCTAssertEqual(streamedEvents, [
            .installer(.phaseStarted(.validatePackage)),
            .installer(.phaseFinished(.validatePackage)),
            .installer(.installResult(.success))
        ])
    }

    func testInstallSelectedPackageDownloadsURLAndCallsConnection() async throws {
        let url = URL(string: "https://example.com/Remote%20App.apk")!
        let contents = makeADBTVTestAPK()
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
            downloadPackage: { downloadURL, progressHandler in
                XCTAssertEqual(downloadURL, url)
                await progressHandler(ADBTVInstallDownloadProgress(
                    receivedByteCount: 0,
                    totalByteCount: Int64(contents.count)
                ))
                await progressHandler(ADBTVInstallDownloadProgress(
                    receivedByteCount: Int64(contents.count),
                    totalByteCount: Int64(contents.count)
                ))
                return ADBTVDownloadedPackage(contents: contents, fileName: "Remote App.apk")
            },
            modificationTime: { 456 }
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
        XCTAssertEqual(connection.installedContents, [contents])
        let installedPath = try XCTUnwrap(connection.installedPlans.first?.remoteAPKPath.rawValue)
        XCTAssertTrue(installedPath.hasPrefix("/data/local/tmp/adbtv/"))
        XCTAssertTrue(installedPath.hasSuffix(".apk"))
        XCTAssertEqual(
            connection.installedPlans.map(\.package.byteCount),
            [Optional(Int64(contents.count))]
        )
        XCTAssertEqual(connection.modificationTimes, [456])
        XCTAssertEqual(streamedEvents, [
            .download(ADBTVInstallDownloadProgress(
                receivedByteCount: 0,
                totalByteCount: Int64(contents.count)
            )),
            .download(ADBTVInstallDownloadProgress(
                receivedByteCount: Int64(contents.count),
                totalByteCount: Int64(contents.count)
            )),
            .installer(.phaseStarted(.validatePackage)),
            .installer(.phaseFinished(.validatePackage)),
            .installer(.installResult(.success))
        ])
    }

    func testInstallSelectedAPKMUsesPackageSessionAndRemovesExtractionDirectory() async throws {
        let archiveURL = URL(fileURLWithPath: "/tmp/app.apkm")
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTVInstallOperationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let baseURL = directoryURL.appendingPathComponent("base.apk")
        let splitURL = directoryURL.appendingPathComponent("split.apk")
        try Data([1]).write(to: baseURL)
        try Data([2]).write(to: splitURL)
        let files = [
            try ADBPackageSessionFile(fileURL: baseURL, fileName: "base.apk", byteCount: 1),
            try ADBPackageSessionFile(fileURL: splitURL, fileName: "split_config.en.apk", byteCount: 1)
        ]
        let preparedAPKM = ADBTVPreparedAPKM(
            files: files,
            temporaryDirectoryURL: directoryURL
        )
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        let model = ADBTVAppModel(
            devices: [device],
            installDraft: ADBTVInstallDraft(
                selectedPackage: ADBTVInstallPackageDraft(fileURL: archiveURL, byteCount: 2)
            )
        )
        var connection = RecordingInstallConnection(result: .success)
        let operation = ADBTVInstallOperation(extractAPKM: { url in
            XCTAssertEqual(url, archiveURL)
            return preparedAPKM
        })
        let eventRecorder = InstallOperationEventRecorder()

        let report = try await operation.installSelectedPackage(
            from: model,
            using: &connection,
            eventHandler: { event in await eventRecorder.record(event) }
        )

        XCTAssertEqual(report.result, .success)
        XCTAssertEqual(connection.installedSessionFiles, [files])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
        let events = await eventRecorder.recordedEvents()
        XCTAssertEqual(events, [
            .installer(.phaseStarted(.validatePackage)),
            .installer(.phaseFinished(.validatePackage)),
            .packageSession(.sessionCreated(id: 7)),
            .packageSession(.installResult(.success))
        ])
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

    func testPrepareRejectsInvalidAPKBeforeDeviceInstallation() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/invalid.apk")
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        let model = ADBTVAppModel(
            devices: [device],
            installDraft: ADBTVInstallDraft(
                selectedPackage: ADBTVInstallPackageDraft(fileURL: fileURL, byteCount: 22)
            )
        )
        let operation = ADBTVInstallOperation(
            readFile: { _ in Array(repeating: 0, count: 22) }
        )

        do {
            _ = try await operation.prepareSelectedPackage(from: model)
            XCTFail("Expected APK validation to fail.")
        } catch let error as ADBAPKValidationError {
            XCTAssertEqual(error, .invalidZIPSignature)
        }
    }

    func testFileReaderRejectsPackageAboveLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTVInstallOperationTests-\(UUID().uuidString).apk")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([1, 2, 3]).write(to: fileURL)

        XCTAssertThrowsError(
            try ADBTVInstallFileReader.readFileBytes(from: fileURL, maximumByteCount: 2)
        ) { error in
            XCTAssertEqual(
                error as? ADBTVInstallFileError,
                .packageTooLarge(maximumByteCount: 2, actualByteCount: 3)
            )
        }
    }
}

private struct RecordingInstallConnection: ADBTVInstallConnection {
    var result: ADBAPKInstallResult
    private(set) var installedContents: [[UInt8]]
    private(set) var installedPlans: [ADBAPKInstallPlan]
    private(set) var modificationTimes: [UInt32]
    private(set) var installedSessionFiles: [[ADBPackageSessionFile]]

    init(result: ADBAPKInstallResult) {
        self.result = result
        self.installedContents = []
        self.installedPlans = []
        self.modificationTimes = []
        self.installedSessionFiles = []
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

    mutating func installAPKM(
        files: [ADBPackageSessionFile],
        eventHandler: @escaping ADBPackageSessionInstallEventHandler
    ) async throws -> ADBAPKInstallResult {
        installedSessionFiles.append(files)
        await eventHandler(.sessionCreated(id: 7))
        await eventHandler(.installResult(result))
        return result
    }
}

private actor InstallOperationEventRecorder {
    private var events: [ADBTVInstallEvent] = []

    func record(_ event: ADBTVInstallEvent) {
        events.append(event)
    }

    func recordedEvents() -> [ADBTVInstallEvent] {
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
