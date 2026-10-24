import ADBClientCore
import Foundation
import Observation

struct ADBTVQuickLaunchIconRequest: Equatable {
    var deviceID: UUID
    var userID: Int?
    var packages: [String]
    var isActive: Bool
    var refreshID: UUID
}

@Observable
@MainActor
final class ADBTVQuickLaunchIcons {
    typealias Loader = @Sendable ([ADBTVInstalledPackage], Int) async throws -> [String: ADBTVInstalledAppDetails]

    private(set) var icons: [String: ADBTVInstalledAppIcon] = [:]
    private(set) var isLoading = false
    private(set) var failure: DiagnosticDetail?
    private var deviceID: UUID?
    private var userID: Int?
    private var requestID: UUID?
    private let cache: ADBTVQuickLaunchIconCache

    nonisolated init(cache: ADBTVQuickLaunchIconCache = .init()) { self.cache = cache }

    func icon(for package: String, deviceID: UUID, userID: Int?) -> ADBTVInstalledAppIcon? {
        guard self.deviceID == deviceID, self.userID == userID, userID != nil else { return nil }
        return icons[package]
    }

    func load(packages: [ADBTVInstalledPackage], deviceID: UUID, userID: Int,
              knownDetails: [String: ADBTVInstalledAppDetails] = [:], loader: @escaping Loader) async throws {
        try Task.checkCancellation()
        guard userID >= 0, packages.count <= ADBTVQuickLaunchStore.maximumAppCount else {
            throw ADBTVQuickLaunchError.invalidUser
        }
        let request = UUID()
        requestID = request
        self.deviceID = deviceID
        self.userID = userID
        let allowed = Set(packages.map(\.packageName))
        icons = cache.load(packages, deviceID: deviceID, userID: userID)
        for (name, details) in knownDetails where allowed.contains(name) {
            if let icon = details.icon { icons[name] = icon }
        }
        failure = nil
        isLoading = !packages.isEmpty
        defer { if requestID == request { isLoading = false } }
        guard !packages.isEmpty else { return }
        do {
            let details = try await loader(packages, userID)
            try Task.checkCancellation()
            guard requestID == request else { return }
            for (name, value) in details where allowed.contains(name) {
                if let icon = value.icon { icons[name] = icon }
            }
            cache.save(icons, packages: packages, deviceID: deviceID, userID: userID)
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            if let appError = error as? ADBTVInstalledAppError,
               case .activeUserChanged = appError {
                icons = [:]
                throw error
            }
            failure = DiagnosticDetail(summary: String(describing: error), context: ["operation": "loadQuickLaunchIcons"])
        }
    }

    func cancel() {
        requestID = nil
        isLoading = false
    }

#if DEBUG
    func preview(_ icons: [String: ADBTVInstalledAppIcon], deviceID: UUID, userID: Int, failure: DiagnosticDetail? = nil) {
        cancel()
        self.icons = icons
        self.deviceID = deviceID
        self.userID = userID
        self.failure = failure
    }
#endif
}
