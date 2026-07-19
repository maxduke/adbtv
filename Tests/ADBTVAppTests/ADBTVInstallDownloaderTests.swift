import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVInstallDownloaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDownloadStreamsProgressAndUsesSuggestedAPKFilename() async throws {
        StubURLProtocol.stub = StubURLResponse(
            statusCode: 200,
            headers: [
                "Content-Disposition": "attachment; filename=\"TV App.apk\"",
                "Content-Length": "4",
                "Content-Type": "application/vnd.android.package-archive"
            ],
            chunks: [Data([1, 2]), Data([3, 4])]
        )
        let recorder = DownloadProgressRecorder()

        let package = try await download(maximumByteCount: 10) { progress in
            await recorder.record(progress)
        }
        defer { try? package.removeTemporaryFiles() }
        let progress = await recorder.values

        XCTAssertEqual(try Data(contentsOf: package.fileURL), Data([1, 2, 3, 4]))
        XCTAssertEqual(package.byteCount, 4)
        XCTAssertEqual(package.fileName, "TV App.apk")
        XCTAssertEqual(progress.first, ADBTVInstallDownloadProgress(
            receivedByteCount: 0,
            totalByteCount: 4
        ))
        XCTAssertEqual(progress.last, ADBTVInstallDownloadProgress(
            receivedByteCount: 4,
            totalByteCount: 4
        ))
        XCTAssertEqual(progress.map(\.receivedByteCount), progress.map(\.receivedByteCount).sorted())
    }

    func testDownloadFallsBackToURLAPKFilename() async throws {
        StubURLProtocol.stub = StubURLResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/octet-stream"],
            chunks: [Data([1])]
        )

        let package = try await download(
            url: URL(string: "https://example.com/Remote%20App.apk")!
        )
        defer { try? package.removeTemporaryFiles() }

        XCTAssertEqual(package.fileName, "Remote App.apk")
    }

    func testDownloadAcceptsSuggestedAPKMFilename() async throws {
        StubURLProtocol.stub = StubURLResponse(
            statusCode: 200,
            headers: ["Content-Disposition": "attachment; filename=\"TV App.apkm\""],
            chunks: [Data([1])]
        )

        let package = try await download()
        defer { try? package.removeTemporaryFiles() }

        XCTAssertEqual(package.fileName, "TV App.apkm")
    }

    func testDownloadRejectsHTTPFailureAndClearlyWrongContentType() async {
        StubURLProtocol.stub = StubURLResponse(statusCode: 404, chunks: [Data([1])])
        await XCTAssertThrowsDownloadError({ try await self.download() }, .unacceptableStatusCode(404))

        StubURLProtocol.stub = StubURLResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/html"],
            chunks: [Data("not an apk".utf8)]
        )
        await XCTAssertThrowsDownloadError(
            { try await self.download() },
            .unacceptableContentType("text/html")
        )
    }

    func testDownloadRejectsAdvertisedAndStreamedOversizeBodies() async {
        StubURLProtocol.stub = StubURLResponse(
            statusCode: 200,
            headers: ["Content-Length": "6"],
            chunks: [Data([1, 2, 3, 4, 5, 6])]
        )
        await XCTAssertThrowsDownloadError(
            { try await self.download(maximumByteCount: 5) },
            .packageTooLarge(maximumByteCount: 5, receivedByteCount: 6)
        )

        StubURLProtocol.stub = StubURLResponse(
            statusCode: 200,
            chunks: [Data([1, 2, 3]), Data([4, 5, 6])]
        )
        await XCTAssertThrowsDownloadError(
            { try await self.download(maximumByteCount: 5) },
            .packageTooLarge(maximumByteCount: 5, receivedByteCount: 6)
        )
    }

    func testDownloadRejectsEmptyBody() async {
        StubURLProtocol.stub = StubURLResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/octet-stream"]
        )

        await XCTAssertThrowsDownloadError({ try await self.download() }, .emptyResponse)
    }

    func testDownloadRejectsInvalidMaximumBeforeStartingRequest() async {
        StubURLProtocol.stub = StubURLResponse(statusCode: 200, chunks: [Data([1])])

        await XCTAssertThrowsDownloadError(
            { try await self.download(maximumByteCount: 0) },
            .invalidMaximumByteCount(0)
        )
        XCTAssertEqual(StubURLProtocol.startCount, 0)
    }

    func testDownloadRejectsUnsupportedSourceSchemeBeforeStartingRequest() async {
        StubURLProtocol.stub = StubURLResponse(statusCode: 200, chunks: [Data([1])])

        await XCTAssertThrowsDownloadError(
            { try await self.download(url: URL(string: "ftp://example.com/app.apk")!) },
            .unsupportedURLScheme("ftp")
        )
        XCTAssertEqual(StubURLProtocol.startCount, 0)
    }

    func testURLPolicyAllowsSecureAndExplicitlyInsecureRedirects() {
        let httpsSource = URL(string: "https://example.com/app.apk")!
        let httpSource = URL(string: "http://example.com/app.apk")!

        XCTAssertNil(ADBTVInstallURLPolicy.violation(
            sourceURL: httpsSource,
            destinationURL: URL(string: "https://cdn.example.com/app.apk")!
        ))
        XCTAssertNil(ADBTVInstallURLPolicy.violation(
            sourceURL: httpSource,
            destinationURL: URL(string: "https://cdn.example.com/app.apk")!
        ))
        XCTAssertNil(ADBTVInstallURLPolicy.violation(
            sourceURL: httpSource,
            destinationURL: URL(string: "http://cdn.example.com/app.apk")!
        ))
    }

    func testURLPolicyRejectsDowngradesAndUnsupportedRedirectSchemes() {
        let httpsSource = URL(string: "https://example.com/app.apk")!

        XCTAssertEqual(
            ADBTVInstallURLPolicy.violation(
                sourceURL: httpsSource,
                destinationURL: URL(string: "http://cdn.example.com/app.apk")!
            ),
            .insecureTransportDowngrade
        )
        XCTAssertEqual(
            ADBTVInstallURLPolicy.violation(
                sourceURL: httpsSource,
                destinationURL: URL(string: "ftp://cdn.example.com/app.apk")!
            ),
            .unsupportedURLScheme("ftp")
        )
    }

    func testCancellingDownloadCancelsURLSessionTask() async {
        StubURLProtocol.stub = StubURLResponse(statusCode: 200, waitsForCancellation: true)
        let task = Task {
            try await download()
        }

        guard await waitUntil({ StubURLProtocol.startCount > 0 }) else {
            task.cancel()
            return XCTFail("The URL loading task did not start.")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error).")
        }

        let didStop = await waitUntil({ StubURLProtocol.stopCount > 0 })
        XCTAssertTrue(didStop, "The URL loading task did not stop after cancellation.")
    }

    private func download(
        url: URL = URL(string: "https://example.com/app.apk")!,
        maximumByteCount: Int64 = 10,
        progressHandler: @escaping ADBTVInstallDownloadProgressHandler = { _ in }
    ) async throws -> ADBTVDownloadedPackage {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return try await ADBTVInstallDownloader.downloadPackage(
            from: url,
            configuration: configuration,
            maximumByteCount: maximumByteCount,
            progressHandler: progressHandler
        )
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct StubURLResponse {
    var statusCode: Int
    var headers: [String: String]
    var chunks: [Data]
    var waitsForCancellation: Bool

    init(
        statusCode: Int,
        headers: [String: String] = [:],
        chunks: [Data] = [],
        waitsForCancellation: Bool = false
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks
        self.waitsForCancellation = waitsForCancellation
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedStub: StubURLResponse?
    private static var storedStartCount = 0
    private static var storedStopCount = 0

    static var stub: StubURLResponse? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedStub
        }
        set {
            lock.lock()
            storedStub = newValue
            lock.unlock()
        }
    }

    static var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCount
    }

    static var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCount
    }

    static func reset() {
        lock.lock()
        storedStub = nil
        storedStartCount = 0
        storedStopCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedStartCount += 1
        let stub = Self.storedStub
        Self.lock.unlock()

        guard let stub,
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !stub.waitsForCancellation else {
            return
        }
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.storedStopCount += 1
        Self.lock.unlock()
    }
}

private actor DownloadProgressRecorder {
    private(set) var values: [ADBTVInstallDownloadProgress] = []

    func record(_ progress: ADBTVInstallDownloadProgress) {
        values.append(progress)
    }
}

private func XCTAssertThrowsDownloadError<T>(
    _ expression: () async throws -> T,
    _ expectedError: ADBTVInstallDownloadError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expectedError) to be thrown.", file: file, line: line)
    } catch let error as ADBTVInstallDownloadError {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("Expected \(expectedError), got \(error).", file: file, line: line)
    }
}
