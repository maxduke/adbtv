import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVInstallOperationTests: XCTestCase {
    func testInstallSelectedPackageStagesFileAndCallsConnection() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/app.apk")
        let contents = makeADBTVTestAPK()
        let preparedAPK = try makePreparedAPK(contents: contents, fileName: "app.apk")
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
            stageAPK: { url, fileName, expectedByteCount in
                XCTAssertEqual(url, fileURL)
                XCTAssertEqual(fileName, "app.apk")
                XCTAssertEqual(expectedByteCount, Int64(contents.count))
                return preparedAPK
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
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: preparedAPK.temporaryDirectoryURL.path
        ))
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
        let downloadedPackage = try makeDownloadedPackage(
            contents: contents,
            fileName: "Remote App.apk"
        )
        var connection = RecordingInstallConnection(result: .success)
        let operation = ADBTVInstallOperation(
            stageAPK: { _, _, _ in
                throw TestInstallOperationError.unexpectedFileStaging
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
                return downloadedPackage
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
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: downloadedPackage.temporaryDirectoryURL.path
        ))
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
        let preparedAPK = try makePreparedAPK(
            contents: Array(repeating: 0, count: 22),
            fileName: "invalid.apk"
        )
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        let model = ADBTVAppModel(
            devices: [device],
            installDraft: ADBTVInstallDraft(
                selectedPackage: ADBTVInstallPackageDraft(fileURL: fileURL, byteCount: 22)
            )
        )
        let operation = ADBTVInstallOperation(
            stageAPK: { _, _, _ in preparedAPK }
        )

        do {
            _ = try await operation.prepareSelectedPackage(from: model)
            XCTFail("Expected APK validation to fail.")
        } catch let error as ADBAPKValidationError {
            XCTAssertEqual(error, .invalidZIPSignature)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: preparedAPK.temporaryDirectoryURL.path
        ))
    }

    func testInstallFailureRemovesStagedPackage() async throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/app.apk")
        let contents = makeADBTVTestAPK()
        let preparedAPK = try makePreparedAPK(contents: contents, fileName: "app.apk")
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        let model = ADBTVAppModel(
            devices: [device],
            installDraft: ADBTVInstallDraft(
                selectedPackage: ADBTVInstallPackageDraft(
                    fileURL: sourceURL,
                    byteCount: Int64(contents.count)
                )
            )
        )
        var connection = RecordingInstallConnection(result: .success, shouldFailInstall: true)
        let operation = ADBTVInstallOperation(stageAPK: { _, _, _ in preparedAPK })

        do {
            _ = try await operation.installSelectedPackage(from: model, using: &connection)
            XCTFail("Expected installation to fail.")
        } catch let error as TestInstallOperationError {
            XCTAssertEqual(error, .installFailed)
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: preparedAPK.temporaryDirectoryURL.path
        ))
    }

    func testFileStagerCopiesPackageIntoOwnedTemporaryDirectory() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTVInstallOperationTests-\(UUID().uuidString).apk")
        let contents = makeADBTVTestAPK()
        try Data(contents).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let preparedAPK = try ADBTVInstallFileStager.stageAPK(
            from: sourceURL,
            fileName: "TV App.apk"
        )

        XCTAssertNotEqual(preparedAPK.fileURL, sourceURL)
        XCTAssertEqual(try Data(contentsOf: preparedAPK.fileURL), Data(contents))
        XCTAssertEqual(preparedAPK.plan.package.byteCount, Int64(contents.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        try preparedAPK.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: preparedAPK.temporaryDirectoryURL.path
        ))
    }

    func testFileStagerRejectsPackageAboveLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTVInstallOperationTests-\(UUID().uuidString).apk")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([1, 2, 3]).write(to: fileURL)

        XCTAssertThrowsError(
            try ADBTVInstallFileStager.stageAPK(
                from: fileURL,
                fileName: "app.apk",
                maximumByteCount: 2
            )
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
    var shouldFailInstall: Bool
    private(set) var installedContents: [[UInt8]]
    private(set) var installedPlans: [ADBAPKInstallPlan]
    private(set) var modificationTimes: [UInt32]
    private(set) var installedSessionFiles: [[ADBPackageSessionFile]]

    init(result: ADBAPKInstallResult, shouldFailInstall: Bool = false) {
        self.result = result
        self.shouldFailInstall = shouldFailInstall
        self.installedContents = []
        self.installedPlans = []
        self.modificationTimes = []
        self.installedSessionFiles = []
    }

    mutating func installAPK(
        fileURL: URL,
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32,
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async throws -> ADBAPKInstallReport {
        installedContents.append(Array(try Data(contentsOf: fileURL)))
        installedPlans.append(plan)
        modificationTimes.append(modificationTime)
        if shouldFailInstall {
            throw TestInstallOperationError.installFailed
        }
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

private enum TestInstallOperationError: Error, Equatable, Sendable {
    case installFailed
    case unexpectedFileStaging
}

private func makePreparedAPK(
    contents: [UInt8],
    fileName: String
) throws -> ADBTVPreparedAPK {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ADBTVPreparedAPKTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    let fileURL = directoryURL.appendingPathComponent("package.apk")
    try Data(contents).write(to: fileURL)
    return ADBTVPreparedAPK(
        fileURL: fileURL,
        plan: try ADBAPKInstallPlan.singleAPK(
            fileName: fileName,
            byteCount: Int64(contents.count)
        ),
        temporaryDirectoryURL: directoryURL
    )
}

private func makeDownloadedPackage(
    contents: [UInt8],
    fileName: String
) throws -> ADBTVDownloadedPackage {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ADBTVDownloadedPackageTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    let fileURL = directoryURL.appendingPathComponent("package")
    try Data(contents).write(to: fileURL)
    return ADBTVDownloadedPackage(
        fileURL: fileURL,
        temporaryDirectoryURL: directoryURL,
        fileName: fileName,
        byteCount: Int64(contents.count)
    )
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
