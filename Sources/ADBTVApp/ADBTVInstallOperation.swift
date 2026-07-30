import ADBClientCore
import Foundation

public protocol ADBTVInstallConnection: Sendable {
    mutating func installAPK(
        fileURL: URL,
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32,
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async throws -> ADBAPKInstallReport

    mutating func installAPKM(
        files: [ADBPackageSessionFile],
        eventHandler: @escaping ADBPackageSessionInstallEventHandler
    ) async throws -> ADBAPKInstallResult
}

public struct ADBTVInstallDownloadProgress: Equatable, Sendable {
    public var receivedByteCount: Int64
    public var totalByteCount: Int64?

    public init(receivedByteCount: Int64, totalByteCount: Int64?) {
        self.receivedByteCount = receivedByteCount
        self.totalByteCount = totalByteCount
    }
}

public enum ADBTVInstallEvent: Equatable, Sendable {
    case download(ADBTVInstallDownloadProgress)
    case installer(ADBAPKInstallEvent)
    case packageSession(ADBPackageSessionInstallEvent)
}

public typealias ADBTVInstallEventHandler = @Sendable (ADBTVInstallEvent) async -> Void
public typealias ADBTVInstallDownloadProgressHandler = @Sendable (
    ADBTVInstallDownloadProgress
) async -> Void

public enum ADBTVInstallPackageLimits {
    public static let maximumByteCount: Int64 = 512 * 1024 * 1024
}

public enum ADBTVPreparedInstallPackage: Equatable, Sendable {
    case singleAPK(ADBTVPreparedAPK)
    case apkm(ADBTVPreparedAPKM)

    public var singleAPKPlan: ADBAPKInstallPlan? {
        guard case .singleAPK(let preparedAPK) = self else {
            return nil
        }
        return preparedAPK.plan
    }

    public func removeTemporaryFiles() throws {
        switch self {
        case .singleAPK(let preparedAPK):
            try preparedAPK.removeTemporaryFiles()
        case .apkm(let preparedAPKM):
            try preparedAPKM.removeTemporaryFiles()
        }
    }
}

public struct ADBTVPreparedAPK: Equatable, Sendable {
    public let fileURL: URL
    public let plan: ADBAPKInstallPlan
    public let temporaryDirectoryURL: URL

    public func removeTemporaryFiles() throws {
        try FileManager.default.removeItem(at: temporaryDirectoryURL)
    }
}

public struct ADBTVInstallReport: Equatable, Sendable {
    public let result: ADBAPKInstallResult

    public init(result: ADBAPKInstallResult) {
        self.result = result
    }
}

public extension ADBTVInstallConnection {
    mutating func installAPK(
        fileURL: URL,
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32
    ) async throws -> ADBAPKInstallReport {
        try await installAPK(
            fileURL: fileURL,
            plan: plan,
            modificationTime: modificationTime,
            eventHandler: { _ in }
        )
    }
}

#if canImport(Network)
extension ADBDeviceConnection: ADBTVInstallConnection {
    public mutating func installAPK(
        fileURL: URL,
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32,
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async throws -> ADBAPKInstallReport {
        try await installAPK(
            fileURL: fileURL,
            plan: plan,
            modificationTime: modificationTime,
            installer: ADBAPKInstaller(),
            eventHandler: eventHandler
        )
    }

    public mutating func installAPKM(
        files: [ADBPackageSessionFile],
        eventHandler: @escaping ADBPackageSessionInstallEventHandler
    ) async throws -> ADBAPKInstallResult {
        try await ADBPackageSessionInstaller().install(
            files: files,
            using: &self,
            eventHandler: eventHandler
        )
    }
}
#endif

public struct ADBTVInstallOperation: Sendable {
    public var stageAPK: @Sendable (
        URL,
        String,
        Int64?
    ) throws -> ADBTVPreparedAPK
    public var downloadPackage: @Sendable (
        URL,
        @escaping ADBTVInstallDownloadProgressHandler
    ) async throws -> ADBTVDownloadedPackage
    public var modificationTime: @Sendable () -> UInt32
    public var extractAPKM: @Sendable (URL) throws -> ADBTVPreparedAPKM

    public init(
        stageAPK: @escaping @Sendable (
            URL,
            String,
            Int64?
        ) throws -> ADBTVPreparedAPK = { url, fileName, expectedByteCount in
            try ADBTVInstallFileStager.stageAPK(
                from: url,
                fileName: fileName,
                expectedByteCount: expectedByteCount
            )
        },
        downloadPackage: @escaping @Sendable (
            URL,
            @escaping ADBTVInstallDownloadProgressHandler
        ) async throws -> ADBTVDownloadedPackage = { url, progressHandler in
            try await ADBTVInstallDownloader.downloadPackage(
                from: url,
                progressHandler: progressHandler
            )
        },
        modificationTime: @escaping @Sendable () -> UInt32 = {
            UInt32(Date().timeIntervalSince1970)
        },
        extractAPKM: @escaping @Sendable (URL) throws -> ADBTVPreparedAPKM = {
            try ADBTVAPKMExtractor().extract(from: $0)
        }
    ) {
        self.stageAPK = stageAPK
        self.downloadPackage = downloadPackage
        self.modificationTime = modificationTime
        self.extractAPKM = extractAPKM
    }

    public func installSelectedPackage<Connection: ADBTVInstallConnection>(
        from model: ADBTVAppModel,
        using connection: inout Connection,
        eventHandler: @escaping ADBTVInstallEventHandler = { _ in }
    ) async throws -> ADBTVInstallReport {
        let package = try await prepareSelectedPackage(
            from: model,
            eventHandler: eventHandler
        )
        defer { try? package.removeTemporaryFiles() }
        return try await installPreparedPackage(
            package,
            using: &connection,
            eventHandler: eventHandler
        )
    }

    public func prepareSelectedPackage(
        from model: ADBTVAppModel,
        eventHandler: @escaping ADBTVInstallEventHandler = { _ in }
    ) async throws -> ADBTVPreparedInstallPackage {
        guard model.selectedDevice != nil else {
            throw ADBTVInstallOperationError.missingDevice
        }

        let package = try await installPayload(
            from: model.installDraft,
            eventHandler: eventHandler
        )
        do {
            if case .singleAPK(let preparedAPK) = package {
                try ADBAPKValidator().validate(fileURL: preparedAPK.fileURL)
            }
        } catch {
            try? package.removeTemporaryFiles()
            throw error
        }
        await eventHandler(.installer(.phaseFinished(.validatePackage)))
        return package
    }

    public func installPreparedPackage<Connection: ADBTVInstallConnection>(
        _ package: ADBTVPreparedInstallPackage,
        using connection: inout Connection,
        eventHandler: @escaping ADBTVInstallEventHandler = { _ in }
    ) async throws -> ADBTVInstallReport {
        switch package {
        case .singleAPK(let preparedAPK):
            let report = try await connection.installAPK(
                fileURL: preparedAPK.fileURL,
                plan: preparedAPK.plan,
                modificationTime: modificationTime(),
                eventHandler: { event in
                    await eventHandler(.installer(event))
                }
            )
            return ADBTVInstallReport(result: report.result)
        case .apkm(let preparedAPKM):
            let result = try await connection.installAPKM(
                files: preparedAPKM.files,
                eventHandler: { event in
                    await eventHandler(.packageSession(event))
                }
            )
            return ADBTVInstallReport(result: result)
        }
    }

    private func installPayload(
        from draft: ADBTVInstallDraft,
        eventHandler: @escaping ADBTVInstallEventHandler
    ) async throws -> ADBTVPreparedInstallPackage {
        if let selectedPackage = draft.selectedPackage {
            guard let fileURL = selectedPackage.fileURL else {
                throw ADBTVInstallOperationError.missingPackageFile
            }

            await eventHandler(.installer(.phaseStarted(.validatePackage)))
            switch draft.packageKind {
            case .singleAPK:
                return .singleAPK(try stageAPK(
                    fileURL,
                    selectedPackage.fileName,
                    selectedPackage.byteCount
                ))
            case .apkm:
                return .apkm(try extractAPKM(fileURL))
            case nil:
                throw ADBTVInstallOperationError.unsupportedPackage(selectedPackage.fileName)
            }
        }

        guard let url = draft.validatedURL,
              let fileName = draft.urlFileName else {
            throw ADBTVInstallOperationError.missingPackage
        }

        let downloadedPackage = try await downloadPackage(url) { progress in
            await eventHandler(.download(progress))
        }
        await eventHandler(.installer(.phaseStarted(.validatePackage)))
        let downloadedFileName = downloadedPackage.fileName ?? fileName
        switch ADBTVInstallPackageKind(fileName: downloadedFileName) {
        case .singleAPK:
            do {
                return .singleAPK(ADBTVPreparedAPK(
                    fileURL: downloadedPackage.fileURL,
                    plan: try ADBAPKInstallPlan.singleAPK(
                        fileName: downloadedFileName,
                        byteCount: downloadedPackage.byteCount
                    ),
                    temporaryDirectoryURL: downloadedPackage.temporaryDirectoryURL
                ))
            } catch {
                try? downloadedPackage.removeTemporaryFiles()
                throw error
            }
        case .apkm:
            defer { try? downloadedPackage.removeTemporaryFiles() }
            return .apkm(try extractAPKM(downloadedPackage.fileURL))
        case nil:
            try? downloadedPackage.removeTemporaryFiles()
            throw ADBTVInstallOperationError.unsupportedPackage(downloadedFileName)
        }
    }
}

public enum ADBTVInstallFileStager: Sendable {
    public static func stageAPK(
        from sourceURL: URL,
        fileName: String,
        expectedByteCount: Int64? = nil,
        maximumByteCount: Int64 = ADBTVInstallPackageLimits.maximumByteCount
    ) throws -> ADBTVPreparedAPK {
        guard maximumByteCount > 0 else {
            throw ADBTVInstallFileError.invalidMaximumByteCount(maximumByteCount)
        }

        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let sourceByteCount = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            throw ADBTVInstallFileError.packageSizeUnavailable
        }
        guard Int64(sourceByteCount) <= maximumByteCount else {
            throw ADBTVInstallFileError.packageTooLarge(
                maximumByteCount: maximumByteCount,
                actualByteCount: Int64(sourceByteCount)
            )
        }

        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTV-APK-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectoryURL,
                withIntermediateDirectories: false
            )
            let stagedFileURL = temporaryDirectoryURL
                .appendingPathComponent("package.apk", isDirectory: false)
            try FileManager.default.copyItem(at: sourceURL, to: stagedFileURL)
            guard let stagedByteCount = try stagedFileURL.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize else {
                throw ADBTVInstallFileError.packageSizeUnavailable
            }
            guard stagedByteCount == sourceByteCount else {
                throw ADBTVInstallFileError.packageChangedDuringStaging(
                    expectedByteCount: sourceByteCount,
                    actualByteCount: stagedByteCount
                )
            }
            return ADBTVPreparedAPK(
                fileURL: stagedFileURL,
                plan: try ADBAPKInstallPlan.singleAPK(
                    fileName: fileName,
                    byteCount: Int64(stagedByteCount)
                ),
                temporaryDirectoryURL: temporaryDirectoryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            throw error
        }
    }
}

public enum ADBTVInstallFileError: Error, Equatable, Sendable {
    case invalidMaximumByteCount(Int64)
    case packageSizeUnavailable
    case packageTooLarge(maximumByteCount: Int64, actualByteCount: Int64)
    case packageChangedDuringStaging(expectedByteCount: Int, actualByteCount: Int)
}

public struct ADBTVDownloadedPackage: Equatable, Sendable {
    public let fileURL: URL
    public let temporaryDirectoryURL: URL
    public let fileName: String?
    public let byteCount: Int64

    public init(
        fileURL: URL,
        temporaryDirectoryURL: URL,
        fileName: String? = nil,
        byteCount: Int64
    ) {
        self.fileURL = fileURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.fileName = fileName
        self.byteCount = byteCount
    }

    public func removeTemporaryFiles() throws {
        try FileManager.default.removeItem(at: temporaryDirectoryURL)
    }
}

public enum ADBTVInstallDownloader: Sendable {
    public static let defaultMaximumByteCount = ADBTVInstallPackageLimits.maximumByteCount

    public static func downloadPackage(
        from url: URL,
        maximumByteCount: Int64 = defaultMaximumByteCount,
        progressHandler: @escaping ADBTVInstallDownloadProgressHandler = { _ in }
    ) async throws -> ADBTVDownloadedPackage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return try await downloadPackage(
            from: url,
            configuration: configuration,
            maximumByteCount: maximumByteCount,
            progressHandler: progressHandler
        )
    }

    static func downloadPackage(
        from url: URL,
        configuration: URLSessionConfiguration,
        maximumByteCount: Int64,
        progressHandler: @escaping ADBTVInstallDownloadProgressHandler
    ) async throws -> ADBTVDownloadedPackage {
        guard maximumByteCount > 0 else {
            throw ADBTVInstallDownloadError.invalidMaximumByteCount(maximumByteCount)
        }
        if let policyError = ADBTVInstallURLPolicy.violation(
            sourceURL: url,
            destinationURL: url
        ) {
            throw policyError
        }

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let delegate = ADBTVInstallDownloadDelegate(
            sourceURL: url,
            maximumByteCount: maximumByteCount,
            progressHandler: progressHandler
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        let task = session.dataTask(with: url)
        defer { session.invalidateAndCancel() }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.start(task: task, continuation: continuation)
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

public enum ADBTVInstallDownloadError: Error, Equatable, Sendable {
    case invalidMaximumByteCount(Int64)
    case unsupportedURLScheme(String?)
    case insecureTransportDowngrade
    case nonHTTPResponse
    case unacceptableStatusCode(Int)
    case unacceptableContentType(String)
    case packageTooLarge(maximumByteCount: Int64, receivedByteCount: Int64)
    case temporaryFileFailure(String)
    case missingResponse
    case emptyResponse
}

enum ADBTVInstallURLPolicy {
    static func violation(
        sourceURL: URL,
        destinationURL: URL
    ) -> ADBTVInstallDownloadError? {
        let sourceScheme = sourceURL.scheme?.lowercased()
        guard sourceScheme == "http" || sourceScheme == "https" else {
            return .unsupportedURLScheme(sourceScheme)
        }

        let destinationScheme = destinationURL.scheme?.lowercased()
        guard destinationScheme == "http" || destinationScheme == "https" else {
            return .unsupportedURLScheme(destinationScheme)
        }
        if sourceScheme == "https", destinationScheme == "http" {
            return .insecureTransportDowngrade
        }
        return nil
    }
}

private final class ADBTVInstallDownloadDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable {
    private let sourceURL: URL
    private let maximumByteCount: Int64
    private let progressHandler: ADBTVInstallDownloadProgressHandler
    private var continuation: CheckedContinuation<ADBTVDownloadedPackage, Error>?
    private var fileHandle: FileHandle?
    private var temporaryDirectoryURL: URL?
    private var downloadedFileURL: URL?
    private var responseFileName: String?
    private var receivedResponse = false
    private var receivedByteCount: Int64 = 0
    private var totalByteCount: Int64?
    private var terminalError: Error?
    private var progressTask: Task<Void, Never>?
    private var lastReportedByteCount: Int64 = -1
    private let minimumProgressIncrement: Int64 = 256 * 1024

    init(
        sourceURL: URL,
        maximumByteCount: Int64,
        progressHandler: @escaping ADBTVInstallDownloadProgressHandler
    ) {
        self.sourceURL = sourceURL
        self.maximumByteCount = maximumByteCount
        self.progressHandler = progressHandler
        super.init()
    }

    func start(
        task: URLSessionDataTask,
        continuation: CheckedContinuation<ADBTVDownloadedPackage, Error>
    ) {
        self.continuation = continuation
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard terminalError == nil else {
            completionHandler(nil)
            return
        }
        guard let destinationURL = request.url else {
            terminalError = ADBTVInstallDownloadError.unsupportedURLScheme(nil)
            completionHandler(nil)
            return
        }
        if let policyError = ADBTVInstallURLPolicy.violation(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        ) {
            terminalError = policyError
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard terminalError == nil else {
            completionHandler(.cancel)
            return
        }
        let expectedByteCount = response.expectedContentLength > 0
            ? response.expectedContentLength
            : nil
        guard let responseURL = response.url else {
            terminalError = ADBTVInstallDownloadError.unsupportedURLScheme(nil)
            completionHandler(.cancel)
            return
        }
        if let policyError = ADBTVInstallURLPolicy.violation(
            sourceURL: sourceURL,
            destinationURL: responseURL
        ) {
            terminalError = policyError
            completionHandler(.cancel)
            return
        }
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            terminalError = ADBTVInstallDownloadError.nonHTTPResponse
            completionHandler(.cancel)
            return
        }
        guard (200 ... 299).contains(statusCode) else {
            terminalError = ADBTVInstallDownloadError.unacceptableStatusCode(statusCode)
            completionHandler(.cancel)
            return
        }
        if let mimeType = response.mimeType, adbTVIsClearlyNotAPK(mimeType: mimeType) {
            terminalError = ADBTVInstallDownloadError.unacceptableContentType(mimeType)
            completionHandler(.cancel)
            return
        }
        if let expectedByteCount, expectedByteCount > maximumByteCount {
            terminalError = ADBTVInstallDownloadError.packageTooLarge(
                maximumByteCount: maximumByteCount,
                receivedByteCount: expectedByteCount
            )
            completionHandler(.cancel)
            return
        }

        receivedResponse = true
        totalByteCount = expectedByteCount
        responseFileName = adbTVInstallPackageFileName(from: response.suggestedFilename)
        do {
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ADBTV-Download-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
            temporaryDirectoryURL = directoryURL
            let fileURL = directoryURL.appendingPathComponent("package", isDirectory: false)
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw ADBTVInstallDownloadError.temporaryFileFailure(
                    "Could not create the download file."
                )
            }
            downloadedFileURL = fileURL
            fileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            terminalError = error
            cleanupTemporaryFiles()
            completionHandler(.cancel)
            return
        }
        reportProgress(receivedByteCount: 0)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard receivedResponse, terminalError == nil else {
            return
        }
        let nextByteCount = receivedByteCount + Int64(data.count)
        guard nextByteCount <= maximumByteCount else {
            terminalError = ADBTVInstallDownloadError.packageTooLarge(
                maximumByteCount: maximumByteCount,
                receivedByteCount: nextByteCount
            )
            dataTask.cancel()
            return
        }

        do {
            guard let fileHandle else {
                throw ADBTVInstallDownloadError.temporaryFileFailure(
                    "The download file is not open."
                )
            }
            try fileHandle.write(contentsOf: data)
            receivedByteCount = nextByteCount
        } catch {
            terminalError = ADBTVInstallDownloadError.temporaryFileFailure(
                String(describing: error)
            )
            dataTask.cancel()
            return
        }
        if let totalByteCount, nextByteCount > totalByteCount {
            self.totalByteCount = nil
        }
        let reachedExpectedByteCount = self.totalByteCount.map {
            nextByteCount >= $0
        } ?? false
        if nextByteCount - lastReportedByteCount >= minimumProgressIncrement
            || reachedExpectedByteCount {
            reportProgress(receivedByteCount: nextByteCount)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        do {
            try fileHandle?.close()
        } catch {
            if terminalError == nil {
                terminalError = ADBTVInstallDownloadError.temporaryFileFailure(
                    String(describing: error)
                )
            }
        }
        fileHandle = nil

        let result: Result<ADBTVDownloadedPackage, Error>
        var keepsTemporaryFiles = false
        if let terminalError {
            result = .failure(terminalError)
        } else if let error {
            result = .failure(error)
        } else if !receivedResponse {
            result = .failure(ADBTVInstallDownloadError.missingResponse)
        } else if receivedByteCount == 0 {
            result = .failure(ADBTVInstallDownloadError.emptyResponse)
        } else if let fileURL = downloadedFileURL,
                  let directoryURL = temporaryDirectoryURL {
            result = .success(ADBTVDownloadedPackage(
                fileURL: fileURL,
                temporaryDirectoryURL: directoryURL,
                fileName: responseFileName ?? adbTVInstallPackageFileName(
                    from: sourceURL.lastPathComponent
                ),
                byteCount: receivedByteCount
            ))
            keepsTemporaryFiles = true
        } else {
            result = .failure(ADBTVInstallDownloadError.temporaryFileFailure(
                "The downloaded file is unavailable."
            ))
        }

        if receivedResponse, terminalError == nil,
           receivedByteCount > 0, lastReportedByteCount != receivedByteCount {
            reportProgress(receivedByteCount: receivedByteCount)
        }
        if !keepsTemporaryFiles {
            cleanupTemporaryFiles()
        }

        let continuation = self.continuation
        self.continuation = nil
        let progressTask = self.progressTask
        Task {
            await progressTask?.value
            continuation?.resume(with: result)
        }
    }

    private func cleanupTemporaryFiles() {
        try? fileHandle?.close()
        fileHandle = nil
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        downloadedFileURL = nil
    }

    private func reportProgress(receivedByteCount: Int64) {
        lastReportedByteCount = receivedByteCount
        let previousTask = progressTask
        let progress = ADBTVInstallDownloadProgress(
            receivedByteCount: receivedByteCount,
            totalByteCount: totalByteCount
        )
        progressTask = Task { [progressHandler] in
            await previousTask?.value
            await progressHandler(progress)
        }
    }
}

private func adbTVInstallPackageFileName(from value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    let decodedValue = value.removingPercentEncoding ?? value
    return ADBTVInstallPackageKind(fileName: decodedValue) == nil ? nil : decodedValue
}

private func adbTVIsClearlyNotAPK(mimeType: String) -> Bool {
    let mimeType = mimeType.lowercased()
    return mimeType.hasPrefix("text/")
        || mimeType == "application/json"
        || mimeType.hasSuffix("+json")
        || mimeType == "application/xml"
        || mimeType.hasSuffix("+xml")
}

public enum ADBTVInstallOperationError: Error, Equatable, Sendable {
    case missingDevice
    case missingPackage
    case missingPackageFile
    case unsupportedPackage(String)
    case unsupportedPlatform
}
