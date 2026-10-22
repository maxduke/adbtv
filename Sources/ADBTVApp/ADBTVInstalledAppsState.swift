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
            return "User"
        case .system:
            return "System"
        case .active:
            return "Active"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .user:
            return "User Apps"
        case .system:
            return "System Apps"
        case .active:
            return "Active Apps"
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
    var mode: ADBTVAppsMode
    var packages: [ADBTVInstalledPackage]
    var details: [String: ADBTVInstalledAppDetails]
    var systemSnapshot: ADBTVSystemAppSnapshot?
    var activitySnapshot: ADBTVAppActivitySnapshot?
    var activityDetails: [String: ADBTVInstalledAppDetails]
    var activeSystemSnapshot: ADBTVSystemAppSnapshot?
    var pendingForceStopPackage: ADBTVInstalledPackage?
    var pendingClearDataPackage: ADBTVInstalledPackage?
    var status: ADBTVInstalledAppsStatus

    init(
        deviceID: ADBTVDeviceSummary.ID? = nil,
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
        self.mode = mode
        self.packages = packages
        self.details = details
        self.systemSnapshot = systemSnapshot
        self.activitySnapshot = activitySnapshot
        self.activityDetails = activityDetails
        self.activeSystemSnapshot = activeSystemSnapshot
        self.pendingForceStopPackage = pendingForceStopPackage
        self.pendingClearDataPackage = pendingClearDataPackage
        self.status = status
    }

    func forDevice(_ deviceID: ADBTVDeviceSummary.ID) -> Self {
        self.deviceID == deviceID ? self : Self(deviceID: deviceID)
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
        return Self(
            deviceID: deviceID,
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
    }
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
