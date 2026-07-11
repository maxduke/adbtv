import ADBClientCore
import Foundation

public protocol ADBTVAPKInstallConnection: Sendable {
    mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32,
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async throws -> ADBAPKInstallReport
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
}

public typealias ADBTVInstallEventHandler = @Sendable (ADBTVInstallEvent) async -> Void
public typealias ADBTVInstallDownloadProgressHandler = @Sendable (
    ADBTVInstallDownloadProgress
) async -> Void

public enum ADBTVInstallPackageLimits {
    public static let maximumByteCount: Int64 = 512 * 1024 * 1024
}

public struct ADBTVPreparedInstallPackage: Equatable, Sendable {
    public var contents: [UInt8]
    public var plan: ADBAPKInstallPlan

    public init(contents: [UInt8], plan: ADBAPKInstallPlan) {
        self.contents = contents
        self.plan = plan
    }
}

public extension ADBTVAPKInstallConnection {
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
extension ADBDeviceConnection: ADBTVAPKInstallConnection {
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
}
#endif

public struct ADBTVInstallOperation: Sendable {
    public var readFile: @Sendable (URL) throws -> [UInt8]
    public var downloadPackage: @Sendable (
        URL,
        @escaping ADBTVInstallDownloadProgressHandler
    ) async throws -> ADBTVDownloadedPackage
    public var modificationTime: @Sendable () -> UInt32

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
        }
    ) {
        self.readFile = readFile
        self.downloadPackage = downloadPackage
        self.modificationTime = modificationTime
    }

    public func installSelectedPackage<Connection: ADBTVAPKInstallConnection>(
        from model: ADBTVAppModel,
        using connection: inout Connection,
        eventHandler: @escaping ADBTVInstallEventHandler = { _ in }
    ) async throws -> ADBAPKInstallReport {
        let package = try await prepareSelectedPackage(
            from: model,
            eventHandler: eventHandler
        )
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
        try ADBAPKValidator().validate(contents: package.contents)
        await eventHandler(.installer(.phaseFinished(.validatePackage)))
        return package
    }

    public func installPreparedPackage<Connection: ADBTVAPKInstallConnection>(
        _ package: ADBTVPreparedInstallPackage,
        using connection: inout Connection,
        eventHandler: @escaping ADBTVInstallEventHandler = { _ in }
    ) async throws -> ADBAPKInstallReport {
        return try await connection.installAPK(
            contents: package.contents,
            plan: package.plan,
            modificationTime: modificationTime(),
            eventHandler: { event in
                await eventHandler(.installer(event))
            }
        )
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
            return try ADBTVPreparedInstallPackage(
                contents: readFile(fileURL),
                plan: draft.installPlan()
            )
        }

        guard let url = draft.validatedURL,
              let fileName = draft.urlFileName else {
            throw ADBTVInstallOperationError.missingPackage
        }

        let downloadedPackage = try await downloadPackage(url) { progress in
            await eventHandler(.download(progress))
        }
        await eventHandler(.installer(.phaseStarted(.validatePackage)))
        return try ADBTVPreparedInstallPackage(
            contents: downloadedPackage.contents,
            plan: ADBAPKInstallPlan.singleAPK(
                fileName: downloadedPackage.fileName ?? fileName,
                byteCount: Int64(downloadedPackage.contents.count)
            )
        )
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
    case nonHTTPResponse
    case unacceptableStatusCode(Int)
    case unacceptableContentType(String)
    case packageTooLarge(maximumByteCount: Int64, receivedByteCount: Int64)
    case missingResponse
    case emptyResponse
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
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let expectedByteCount = response.expectedContentLength > 0
            ? response.expectedContentLength
            : nil
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
        responseFileName = adbTVAPKFileName(from: response.suggestedFilename)
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
                fileName: responseFileName ?? adbTVAPKFileName(from: sourceURL.lastPathComponent)
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

private func adbTVAPKFileName(from value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    let decodedValue = value.removingPercentEncoding ?? value
    return decodedValue.lowercased().hasSuffix(".apk") ? decodedValue : nil
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
    case unsupportedPlatform
}
