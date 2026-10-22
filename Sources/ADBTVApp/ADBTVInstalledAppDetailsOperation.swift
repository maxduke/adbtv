import ADBClientCore
import Foundation

enum ADBTVInstalledAppDetailsLoadResult: Equatable, Sendable {
    case complete
    case helperUnavailable
    case partial(packages: [ADBTVInstalledPackage], failure: String)
}

struct ADBTVInstalledAppDetailsOperation: Sendable {
    typealias PageLoader = @Sendable (
        [ADBTVInstalledPackage], Int
    ) async throws -> [String: ADBTVInstalledAppDetails]
    typealias PageHandler = @Sendable (
        [ADBTVInstalledPackage], [String: ADBTVInstalledAppDetails]
    ) async -> Void

    private let pageSize: Int
    private let loadPage: PageLoader

    init(pageSize: Int = 128, loadPage: @escaping PageLoader) {
        precondition(pageSize > 0)
        self.pageSize = pageSize
        self.loadPage = loadPage
    }

    func load(
        _ packages: [ADBTVInstalledPackage],
        userID: Int,
        onPage: @escaping PageHandler
    ) async throws -> ADBTVInstalledAppDetailsLoadResult {
        var failedPackages: [ADBTVInstalledPackage] = []
        var firstFailure: String?
        for start in stride(from: 0, to: packages.count, by: pageSize) {
            try Task.checkCancellation()
            let page = Array(packages[start ..< min(start + pageSize, packages.count)])
            do {
                let details = try await loadPage(page, userID)
                try Task.checkCancellation()
                await onPage(page, details)
            } catch {
                try Task.checkCancellation()
                if let appError = error as? ADBTVInstalledAppError {
                    switch appError {
                    case .detailsHelperUnavailable:
                        return .helperUnavailable
                    case .activeUserChanged, .invalidUserID:
                        throw error
                    default:
                        break
                    }
                }
                if error is CancellationError { throw error }
                failedPackages.append(contentsOf: page)
                if firstFailure == nil { firstFailure = String(describing: error) }
            }
        }
        try Task.checkCancellation()
        if let firstFailure {
            return .partial(packages: failedPackages, failure: firstFailure)
        }
        return .complete
    }
}
