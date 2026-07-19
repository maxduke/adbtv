import ADBClientCore
import Foundation

public protocol ADBTVInstallConnection: Sendable {
    mutating func installAPK(
        contents: [UInt8],
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
    case singleAPK(contents: [UInt8], plan: ADBAPKInstallPlan)
    case apkm(ADBTVPreparedAPKM)

    public var singleAPKPlan: ADBAPKInstallPlan? {
        guard case .singleAPK(_, let plan) = self else {
            return nil
        }
        return plan
    }

    public func removeTemporaryFiles() throws {
        if case .apkm(let preparedAPKM) = self {
            try preparedAPKM.removeTemporaryFiles()
        }
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
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32
    ) async throws -> ADBAPKInstallReport {
        try await installAPK(
            contents: contents,
            plan: plan,
            modificationTime: modificationTime,
            eventHandler: { _ in }
        )
    }
}

#if canImport(Network)
extension ADBDeviceConnection: ADBTVInstallConnection {
    public mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32,
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async throws -> ADBAPKInstallReport {
        try await installAPK(
            contents: contents,
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
    public var readFile: @Sendable (URL) throws -> [UInt8]
    public var downloadPackage: @Sendable (
        URL,
        @escaping ADBTVInstallDownloadProgressHandler
    ) async throws -> ADBTVDownloadedPackage
    public var modificationTime: @Sendable () -> UInt32
    public var extractAPKM: @Sendable (URL) throws -> ADBTVPreparedAPKM

    public init(
        readFile: @escaping @Sendable (URL) throws -> [UInt8] = {
            try ADBTVInstallFileReader.readFileBytes(from: $0)
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
        self.readFile = readFile
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
        if case .singleAPK(let contents, _) = package {
            try ADBAPKValidator().validate(contents: contents)
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
        case .singleAPK(let contents, let plan):
            let report = try await connection.installAPK(
                contents: contents,
                plan: plan,
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
                return .singleAPK(
                    contents: try readFile(fileURL),
                    plan: try draft.installPlan()
                )
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
            return .singleAPK(
                contents: downloadedPackage.contents,
                plan: try ADBAPKInstallPlan.singleAPK(
                    fileName: downloadedFileName,
                    byteCount: Int64(downloadedPackage.contents.count)
                )
            )
        case .apkm:
            let temporaryArchiveURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ADBTV-\(UUID().uuidString).apkm")
            try Data(downloadedPackage.contents).write(to: temporaryArchiveURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryArchiveURL) }
            return .apkm(try extractAPKM(temporaryArchiveURL))
        case nil:
            throw ADBTVInstallOperationError.unsupportedPackage(downloadedFileName)
        }
    }
}

public enum ADBTVInstallFileReader: Sendable {
    public static func readFileBytes(
        from url: URL,
        maximumByteCount: Int64 = ADBTVInstallPackageLimits.maximumByteCount
    ) throws -> [UInt8] {
        guard maximumByteCount > 0 else {
            throw ADBTVInstallFileError.invalidMaximumByteCount(maximumByteCount)
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(fileSize) > maximumByteCount {
            throw ADBTVInstallFileError.packageTooLarge(
                maximumByteCount: maximumByteCount,
                actualByteCount: Int64(fileSize)
            )
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Int64(data.count) <= maximumByteCount else {
            throw ADBTVInstallFileError.packageTooLarge(
                maximumByteCount: maximumByteCount,
                actualByteCount: Int64(data.count)
            )
        }
        return Array(data)
    }
}

public enum ADBTVInstallFileError: Error, Equatable, Sendable {
    case invalidMaximumByteCount(Int64)
    case packageTooLarge(maximumByteCount: Int64, actualByteCount: Int64)
}

public struct ADBTVDownloadedPackage: Equatable, Sendable {
    public var contents: [UInt8]
    public var fileName: String?

    public init(contents: [UInt8], fileName: String? = nil) {
        self.contents = contents
        self.fileName = fileName
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
    private var contents: [UInt8] = []
    private var responseFileName: String?
    private var receivedResponse = false
    private var totalByteCount: Int64?
    private var terminalError: ADBTVInstallDownloadError?
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
            terminalError = .unsupportedURLScheme(nil)
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
            terminalError = .unsupportedURLScheme(nil)
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
            terminalError = .nonHTTPResponse
            completionHandler(.cancel)
            return
        }
        guard (200 ... 299).contains(statusCode) else {
            terminalError = .unacceptableStatusCode(statusCode)
            completionHandler(.cancel)
            return
        }
        if let mimeType = response.mimeType, adbTVIsClearlyNotAPK(mimeType: mimeType) {
            terminalError = .unacceptableContentType(mimeType)
            completionHandler(.cancel)
            return
        }
        if let expectedByteCount, expectedByteCount > maximumByteCount {
            terminalError = .packageTooLarge(
                maximumByteCount: maximumByteCount,
                receivedByteCount: expectedByteCount
            )
            completionHandler(.cancel)
            return
        }

        receivedResponse = true
        totalByteCount = expectedByteCount
        responseFileName = adbTVInstallPackageFileName(from: response.suggestedFilename)
        if let expectedByteCount,
           let capacity = Int(exactly: expectedByteCount) {
            contents.reserveCapacity(capacity)
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
        let nextByteCount = Int64(contents.count) + Int64(data.count)
        guard nextByteCount <= maximumByteCount else {
            terminalError = .packageTooLarge(
                maximumByteCount: maximumByteCount,
                receivedByteCount: nextByteCount
            )
            dataTask.cancel()
            return
        }

        contents.append(contentsOf: data)
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
        let result: Result<ADBTVDownloadedPackage, Error>
        if let terminalError {
            result = .failure(terminalError)
        } else if let error {
            result = .failure(error)
        } else if !receivedResponse {
            result = .failure(ADBTVInstallDownloadError.missingResponse)
        } else if contents.isEmpty {
            result = .failure(ADBTVInstallDownloadError.emptyResponse)
        } else {
            result = .success(ADBTVDownloadedPackage(
                contents: contents,
                fileName: responseFileName ?? adbTVInstallPackageFileName(
                    from: sourceURL.lastPathComponent
                )
            ))
        }

        if receivedResponse, terminalError == nil,
           !contents.isEmpty, lastReportedByteCount != Int64(contents.count) {
            reportProgress(receivedByteCount: Int64(contents.count))
        }

        let continuation = self.continuation
        self.continuation = nil
        let progressTask = self.progressTask
        Task {
            await progressTask?.value
            continuation?.resume(with: result)
        }
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
