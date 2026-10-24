import ADBClientCore
import Foundation

enum ADBTVAppsMode: String, CaseIterable, Identifiable {
    case user
    case system
    case active

    var id: Self { self }

    var title: String {
        switch self {
        case .user:
            return adbTVLocalized("User")
        case .system:
            return adbTVLocalized("System")
        case .active:
            return adbTVLocalized("Active")
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .user:
            return adbTVLocalized("User Apps")
        case .system:
            return adbTVLocalized("System Apps")
        case .active:
            return adbTVLocalized("Active Apps")
        }
    }

    var scope: ADBTVInstalledAppScope? {
        switch self {
        case .user:
            return .user
        case .system:
            return .system
        case .active:
            return nil
        }
    }
}

struct ADBTVInstalledAppsViewState: Equatable {
    var deviceID: ADBTVDeviceSummary.ID?
    var userID: Int?
    var mode: ADBTVAppsMode
    var packages: [ADBTVInstalledPackage]
    var details: [String: ADBTVInstalledAppDetails]
    var systemSnapshot: ADBTVSystemAppSnapshot?
    var activitySnapshot: ADBTVAppActivitySnapshot? {
        didSet { activeAppsByPackage = Self.indexActiveApps(activitySnapshot) }
    }
    private(set) var activeAppsByPackage: [String: ADBTVActiveApp]
    var activityDetails: [String: ADBTVInstalledAppDetails]
    var activeSystemSnapshot: ADBTVSystemAppSnapshot?
    var pendingForceStopPackage: ADBTVInstalledPackage?
    var pendingClearDataPackage: ADBTVInstalledPackage?
    var status: ADBTVInstalledAppsStatus
    var detailsStatus = ADBTVInstalledAppDetailsStatus.idle
    var pendingDetailsPackages: [ADBTVInstalledPackage] = []

    init(
        deviceID: ADBTVDeviceSummary.ID? = nil,
        userID: Int? = nil,
        mode: ADBTVAppsMode = .user,
        packages: [ADBTVInstalledPackage] = [],
        details: [String: ADBTVInstalledAppDetails] = [:],
        systemSnapshot: ADBTVSystemAppSnapshot? = nil,
        activitySnapshot: ADBTVAppActivitySnapshot? = nil,
        activityDetails: [String: ADBTVInstalledAppDetails] = [:],
        activeSystemSnapshot: ADBTVSystemAppSnapshot? = nil,
        pendingForceStopPackage: ADBTVInstalledPackage? = nil,
        pendingClearDataPackage: ADBTVInstalledPackage? = nil,
        status: ADBTVInstalledAppsStatus = .idle
    ) {
        self.deviceID = deviceID
        self.userID = userID
        self.mode = mode
        self.packages = packages
        self.details = details
        self.systemSnapshot = systemSnapshot
        self.activitySnapshot = activitySnapshot
        self.activeAppsByPackage = Self.indexActiveApps(activitySnapshot)
        self.activityDetails = activityDetails
        self.activeSystemSnapshot = activeSystemSnapshot
        self.pendingForceStopPackage = pendingForceStopPackage
        self.pendingClearDataPackage = pendingClearDataPackage
        self.status = status
    }

    func forDevice(_ deviceID: ADBTVDeviceSummary.ID) -> Self {
        self.deviceID == deviceID ? self : Self(deviceID: deviceID)
    }

    var displayedPackages: [ADBTVInstalledPackage] {
        mode == .active ? activitySnapshot?.apps.map(\.package) ?? [] : packages
    }

    var displayedDetails: [String: ADBTVInstalledAppDetails] {
        mode == .active ? activityDetails : details
    }

    var hasSnapshot: Bool {
        mode == .active ? activitySnapshot != nil : userID != nil
    }

    func filteredPackages(matching search: String) -> [ADBTVInstalledPackage] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return displayedPackages }
        return displayedPackages.filter {
            $0.packageName.localizedCaseInsensitiveContains(query)
                || displayedDetails[$0.packageName]?.displayName?
                    .localizedCaseInsensitiveContains(query) == true
        }
    }

    func emptyState(matching search: String) -> ADBTVAppsEmptyState? {
        guard case .ready = status, hasSnapshot else { return nil }
        return emptyState(filteredPackages: filteredPackages(matching: search))
    }

    func emptyState(filteredPackages: [ADBTVInstalledPackage]) -> ADBTVAppsEmptyState? {
        guard case .ready = status, hasSnapshot,
              filteredPackages.isEmpty else {
            return nil
        }
        return displayedPackages.isEmpty ? .noApps : .noMatches
    }

    private static func indexActiveApps(_ snapshot: ADBTVAppActivitySnapshot?) -> [String: ADBTVActiveApp] {
        var result: [String: ADBTVActiveApp] = [:]
        for app in snapshot?.apps ?? [] where result[app.package.packageName] == nil {
            result[app.package.packageName] = app
        }
        return result
    }

    mutating func prepareListRefresh(mode: ADBTVAppsMode) {
        if self.mode != mode {
            packages = []
            userID = nil
            details = [:]
            systemSnapshot = nil
        }
        self.mode = mode
        pendingDetailsPackages = []
        detailsStatus = .idle
    }

    mutating func recordListSnapshot(
        _ packages: [ADBTVInstalledPackage],
        userID: Int,
        systemSnapshot: ADBTVSystemAppSnapshot? = nil
    ) {
        self.userID = userID
        self.packages = packages
        self.systemSnapshot = systemSnapshot
        details = [:]
        status = .ready(message: nil)
    }

    mutating func prepareActivityRefresh() {
        mode = .active
        // The previous Active snapshot stays visible during refresh/cancel.
        // Its rows must retain their own user even when entered from User Apps.
        userID = activitySnapshot?.userID
        pendingDetailsPackages = []
        detailsStatus = .idle
    }

    mutating func recordDetailsPage(
        _ details: [String: ADBTVInstalledAppDetails],
        packages: [ADBTVInstalledPackage],
        forActivity: Bool
    ) {
        let currentPackages = Set(
            forActivity
                ? activitySnapshot?.apps.map(\.package.packageName) ?? []
                : self.packages.map(\.packageName)
        )
        let filtered = details.filter { currentPackages.contains($0.key) }
        if forActivity {
            activityDetails.merge(filtered) { _, latest in latest }
        } else {
            self.details.merge(filtered) { _, latest in latest }
        }
        let completed = Set(packages)
        pendingDetailsPackages.removeAll { completed.contains($0) }
    }

    mutating func finishDetailsLoad(_ result: ADBTVInstalledAppDetailsLoadResult) {
        switch result {
        case .complete:
            pendingDetailsPackages = []
            detailsStatus = .ready
        case .helperUnavailable:
            pendingDetailsPackages = []
            detailsStatus = .helperUnavailable
        case .partial(let packages, let failure):
            pendingDetailsPackages = packages
            detailsStatus = .failed(failure)
        }
    }

    mutating func setSystemState(
        _ state: ADBTVInstalledAppState,
        for package: ADBTVInstalledPackage
    ) {
        if mode == .active {
            activeSystemSnapshot = Self.settingSystemState(
                state,
                for: package,
                in: activeSystemSnapshot
            )
            return
        }
        systemSnapshot = Self.settingSystemState(state, for: package, in: systemSnapshot)
    }

    private static func settingSystemState(
        _ state: ADBTVInstalledAppState,
        for package: ADBTVInstalledPackage,
        in snapshot: ADBTVSystemAppSnapshot?
    ) -> ADBTVSystemAppSnapshot? {
        guard let snapshot else {
            return nil
        }
        var disabledPackageNames = snapshot.disabledPackageNames
        if state == .disabled {
            disabledPackageNames.insert(package.packageName)
        } else {
            disabledPackageNames.remove(package.packageName)
        }
        return ADBTVSystemAppSnapshot(
            userID: snapshot.userID,
            packages: snapshot.packages,
            disabledPackageNames: disabledPackageNames,
            protectionReasons: snapshot.protectionReasons,
            safetyCheckFailureDescription: snapshot.safetyCheckFailureDescription
        )
    }

    static func preview(deviceID: ADBTVDeviceSummary.ID) -> Self {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-apps-empty") {
            return Self(deviceID: deviceID, userID: 0, status: .ready(message: nil))
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-apps-failed") {
            return Self(
                deviceID: deviceID,
                status: .failed(
                    userMessage: adbTVLocalized("Could not load installed apps. Check the TV connection and try again."),
                    diagnosticDetail: DiagnosticDetail(summary: "Preview request timed out.")
                )
            )
        }
#endif
        let packageNames = [
            "com.disney.disneyplus",
            "com.google.android.youtube.tv",
            "com.netflix.ninja",
            "com.example.very.long.android.television.streaming.application"
        ]
        let packages = packageNames.compactMap {
            try? ADBTVInstalledPackage(packageName: $0)
        }
        let showsSystemControl = ProcessInfo.processInfo.arguments.contains(
            "--ui-app-details"
        )
        let showsActivity = ProcessInfo.processInfo.arguments.contains("--ui-active")
        let details = [
            packageNames[0]: ADBTVInstalledAppDetails(
                displayName: "Disney+",
                versionName: "4.18.0",
                versionCode: 418_000,
                firstInstallTimeMilliseconds: 1_704_067_200_000,
                lastUpdateTimeMilliseconds: 1_719_792_000_000,
                apkByteCount: 38_797_312
            ),
            packageNames[1]: ADBTVInstalledAppDetails(displayName: "YouTube"),
            packageNames[2]: ADBTVInstalledAppDetails(displayName: "Netflix"),
            packageNames[3]: ADBTVInstalledAppDetails(
                displayName: "A Streaming App With a Longer Name"
            )
        ]
        let previewSystemSnapshot = ADBTVSystemAppSnapshot(
            userID: 0,
            packages: packages,
            disabledPackageNames: [],
            protectionReasons: [
                packageNames[1]: .activeLauncher
            ]
        )
        let activityApps = [
            ADBTVActiveApp(
                package: packages[2],
                kind: .user,
                isForeground: true,
                memoryByteCount: 251_658_240,
                processCount: 2
            ),
            ADBTVActiveApp(
                package: packages[1],
                kind: .system,
                isForeground: false,
                memoryByteCount: 98_566_144,
                processCount: 1
            ),
            ADBTVActiveApp(
                package: packages[3],
                kind: .user,
                isForeground: false,
                memoryByteCount: nil,
                processCount: 3
            )
        ]
        var state = Self(
            deviceID: deviceID,
            userID: 0,
            mode: showsActivity ? .active : showsSystemControl ? .system : .user,
            packages: packages,
            details: details,
            systemSnapshot: showsSystemControl && !showsActivity
                ? previewSystemSnapshot : nil,
            activitySnapshot: showsActivity
                ? ADBTVAppActivitySnapshot(
                    userID: 0,
                    apps: activityApps,
                    capturedAt: Date(),
                    diagnostics: ADBTVAppActivityDiagnostics(
                        missingMemoryProcessCount: 1
                    )
                )
                : nil,
            activityDetails: showsActivity ? details : [:],
            activeSystemSnapshot: showsActivity && showsSystemControl
                ? previewSystemSnapshot : nil,
            status: .ready(message: nil)
        )
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-apps-refresh-failed") {
            state.status = .failed(
                userMessage: adbTVLocalized("Could not refresh apps. Showing the previous list."),
                diagnosticDetail: DiagnosticDetail(summary: "Preview refresh timed out.")
            )
        }
#endif
        return state
    }
}

enum ADBTVAppsEmptyState: Equatable {
    case noApps
    case noMatches
}

enum ADBTVInstalledAppDetailsStatus: Equatable {
    case idle
    case loading
    case ready
    case helperUnavailable
    case failed(String)
}

enum ADBTVInstalledAppsStatus: Equatable {
    case idle
    case loading
    case loadingActivity
    case loadingSystemControl
    case ready(message: String?)
    case launching(ADBTVInstalledPackage)
    case stopping(ADBTVInstalledPackage)
    case uninstalling(ADBTVInstalledPackage)
    case openingSettings(ADBTVInstalledPackage)
    case clearingData(ADBTVInstalledPackage)
    case disabling(ADBTVInstalledPackage)
    case restoringDefault(ADBTVInstalledPackage)
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    var isBusy: Bool {
        switch self {
        case .loading, .loadingActivity, .loadingSystemControl,
             .launching, .stopping, .uninstalling, .openingSettings, .clearingData,
             .disabling, .restoringDefault:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    var isActivityRefresh: Bool {
        self == .loadingActivity || self == .loadingSystemControl
    }
}
