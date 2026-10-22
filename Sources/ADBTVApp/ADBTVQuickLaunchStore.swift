import ADBClientCore
import Foundation

struct ADBTVPinnedApp: Codable, Equatable, Identifiable, Sendable {
    var id: String { packageName }
    let packageName: String
    let displayName: String?

    init(package: ADBTVInstalledPackage, displayName: String? = nil) {
        packageName = package.packageName
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = name.flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
    }

    var title: String { displayName ?? packageName }
}

enum ADBTVQuickLaunchError: Error, Equatable {
    case invalidArchive
    case invalidUser
    case limitReached
    case changedOrder
    case deviceBusy

    var userMessage: String {
        switch self {
        case .invalidArchive:
            return adbTVLocalized("Saved Quick Launch apps could not be read. Existing preferences were preserved.")
        case .invalidUser:
            return adbTVLocalized("The TV user could not be verified. Refresh Quick Launch and try again.")
        case .limitReached:
            return adbTVLocalized("You can pin up to six apps for each TV user. Remove an app before adding another.")
        case .changedOrder:
            return adbTVLocalized("Pinned apps changed. Reopen Manage to reorder the current list.")
        case .deviceBusy:
            return adbTVLocalized("Another TV operation is in progress. Try again when it finishes.")
        }
    }
}

struct ADBTVQuickLaunchStore {
    static let maximumAppCount = 6
    private static let maximumArchiveByteCount = 256 * 1024

    var userDefaults: UserDefaults = .standard
    var keyPrefix = "ADBTV.quickLaunch."

    private struct UserApps: Codable {
        var userID: Int
        var apps: [ADBTVPinnedApp]
    }

    func hasSavedApps(deviceID: UUID) -> Bool {
        userDefaults.object(forKey: key(deviceID)) != nil
    }

    func apps(deviceID: UUID, userID: Int) throws -> [ADBTVPinnedApp] {
        guard userID >= 0 else { throw ADBTVQuickLaunchError.invalidUser }
        return try archive(deviceID).first { $0.userID == userID }?.apps ?? []
    }

    @discardableResult
    func pin(
        _ package: ADBTVInstalledPackage,
        displayName: String?,
        deviceID: UUID,
        userID: Int
    ) throws -> [ADBTVPinnedApp] {
        try update(deviceID: deviceID, userID: userID) { apps in
            if let index = apps.firstIndex(where: { $0.packageName == package.packageName }) {
                let updated = ADBTVPinnedApp(package: package, displayName: displayName)
                if updated.displayName != nil { apps[index] = updated }
            } else {
                guard apps.count < Self.maximumAppCount else {
                    throw ADBTVQuickLaunchError.limitReached
                }
                apps.append(ADBTVPinnedApp(package: package, displayName: displayName))
            }
        }
    }

    @discardableResult
    func remove(
        packageNames: Set<String>, deviceID: UUID, userID: Int
    ) throws -> [ADBTVPinnedApp] {
        try update(deviceID: deviceID, userID: userID) { apps in
            apps.removeAll { packageNames.contains($0.packageName) }
        }
    }

    @discardableResult
    func reorder(
        packageNames: [String], deviceID: UUID, userID: Int
    ) throws -> [ADBTVPinnedApp] {
        try update(deviceID: deviceID, userID: userID) { apps in
            guard packageNames.count == apps.count,
                  Set(packageNames).count == apps.count,
                  Set(packageNames) == Set(apps.map(\.packageName)) else {
                throw ADBTVQuickLaunchError.changedOrder
            }
            let byName = Dictionary(uniqueKeysWithValues: apps.map { ($0.packageName, $0) })
            apps = packageNames.compactMap { byName[$0] }
        }
    }

    func removeDevice(_ deviceID: UUID) {
        userDefaults.removeObject(forKey: key(deviceID))
    }

    private func key(_ deviceID: UUID) -> String { keyPrefix + deviceID.uuidString }

    private func archive(_ deviceID: UUID) throws -> [UserApps] {
        let key = key(deviceID)
        guard userDefaults.object(forKey: key) != nil else { return [] }
        guard let data = userDefaults.data(forKey: key),
              data.count <= Self.maximumArchiveByteCount,
              let users = try? JSONDecoder().decode([UserApps].self, from: data) else {
            throw ADBTVQuickLaunchError.invalidArchive
        }
        guard Set(users.map(\.userID)).count == users.count else {
            throw ADBTVQuickLaunchError.invalidArchive
        }
        for user in users {
            guard user.userID >= 0, user.apps.count <= Self.maximumAppCount,
                  Set(user.apps.map(\.packageName)).count == user.apps.count else {
                throw ADBTVQuickLaunchError.invalidArchive
            }
            for app in user.apps {
                guard app.packageName.utf8.count <= 256,
                      (try? ADBTVInstalledPackage(packageName: app.packageName)) != nil,
                      app.displayName.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 256 }) ?? true else {
                    throw ADBTVQuickLaunchError.invalidArchive
                }
            }
        }
        return users
    }

    private func update(
        deviceID: UUID, userID: Int,
        mutation: (inout [ADBTVPinnedApp]) throws -> Void
    ) throws -> [ADBTVPinnedApp] {
        guard userID >= 0 else { throw ADBTVQuickLaunchError.invalidUser }
        var users = try archive(deviceID)
        var apps = users.first { $0.userID == userID }?.apps ?? []
        try mutation(&apps)
        guard apps.allSatisfy({ $0.packageName.utf8.count <= 256 }) else {
            throw ADBTVQuickLaunchError.invalidArchive
        }
        users.removeAll { $0.userID == userID }
        if !apps.isEmpty { users.append(UserApps(userID: userID, apps: apps)) }
        if users.isEmpty {
            userDefaults.removeObject(forKey: key(deviceID))
        } else {
            let data = try JSONEncoder().encode(users)
            guard data.count <= Self.maximumArchiveByteCount else {
                throw ADBTVQuickLaunchError.invalidArchive
            }
            userDefaults.set(data, forKey: key(deviceID))
        }
        return apps
    }
}
