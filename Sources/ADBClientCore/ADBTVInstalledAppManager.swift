import Foundation

public enum ADBTVInstalledAppScope: String, CaseIterable, Hashable, Sendable {
    case user
    case system
}

public struct ADBTVInstalledPackage: Hashable, Identifiable, Sendable {
    public var id: String { packageName }
    public let packageName: String

    public init(packageName: String) throws {
        guard !packageName.isEmpty,
              packageName.first != ".",
              packageName.last != ".",
              !packageName.contains(".."),
              packageName.unicodeScalars.allSatisfy(Self.isAllowedPackageScalar) else {
            throw ADBTVInstalledAppError.invalidPackageName(packageName)
        }
        self.packageName = packageName
    }

    fileprivate var shellEscaped: String {
        "'\(packageName)'"
    }

    private static func isAllowedPackageScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48 ... 57, 65 ... 90, 97 ... 122, 95:
            return true
        case 46:
            return true
        default:
            return false
        }
    }
}

public struct ADBTVInstalledAppIcon: Equatable, Sendable {
    public static let maximumPNGByteCount = 48 * 1024
    public static let maximumPixelDimension = 128

    public let pngData: Data

    public init(pngData: Data) throws {
        guard pngData.count <= Self.maximumPNGByteCount else {
            throw ADBTVInstalledAppError.iconPNGTooLarge(pngData.count)
        }

        let header = Array(pngData.prefix(24))
        guard header.count == 24,
              Array(header[0 ..< 8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(header[12 ..< 16]) == Array("IHDR".utf8) else {
            throw ADBTVInstalledAppError.invalidIconPNG
        }

        let width = Self.pngDimension(header[16 ..< 20])
        let height = Self.pngDimension(header[20 ..< 24])
        guard (1 ... Self.maximumPixelDimension).contains(width),
              (1 ... Self.maximumPixelDimension).contains(height) else {
            throw ADBTVInstalledAppError.invalidIconDimensions(width: width, height: height)
        }
        self.pngData = pngData
    }

    private static func pngDimension(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }
}

public struct ADBTVInstalledAppDetails: Equatable, Sendable {
    private static let maximumTextLength = 256

    public let displayName: String?
    public let versionName: String?
    public let versionCode: Int64?
    public let firstInstallDate: Date?
    public let lastUpdateDate: Date?
    public let apkByteCount: Int64?
    public let icon: ADBTVInstalledAppIcon?
    public var isStopped: Bool?

    public init(
        displayName: String? = nil,
        versionName: String? = nil,
        versionCode: Int64? = nil,
        firstInstallTimeMilliseconds: Int64? = nil,
        lastUpdateTimeMilliseconds: Int64? = nil,
        apkByteCount: Int64? = nil,
        icon: ADBTVInstalledAppIcon? = nil,
        isStopped: Bool? = nil
    ) {
        self.displayName = Self.validatedText(displayName)
        self.versionName = Self.validatedText(versionName)
        self.versionCode = versionCode.flatMap { $0 >= 0 ? $0 : nil }
        self.firstInstallDate = Self.date(milliseconds: firstInstallTimeMilliseconds)
        self.lastUpdateDate = Self.date(milliseconds: lastUpdateTimeMilliseconds)
        self.apkByteCount = apkByteCount.flatMap { $0 > 0 ? $0 : nil }
        self.icon = icon
        self.isStopped = isStopped
    }

    private static func validatedText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.count <= maximumTextLength,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static func date(milliseconds: Int64?) -> Date? {
        guard let milliseconds, milliseconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

public enum ADBTVInstalledAppState: Equatable, Sendable {
    case enabled
    case disabled
}

public enum ADBTVInstalledAppProtectionReason: String, Equatable, Sendable {
    case androidCore
    case ecosystemInfrastructure
    case activeLauncher
    case settings
    case activeInputMethod
}

public struct ADBTVSystemAppSnapshot: Equatable, Sendable {
    public let userID: Int
    public let packages: [ADBTVInstalledPackage]
    public let disabledPackageNames: Set<String>
    public let protectionReasons: [String: ADBTVInstalledAppProtectionReason]
    public let safetyCheckFailureDescription: String?

    public init(
        userID: Int,
        packages: [ADBTVInstalledPackage],
        disabledPackageNames: Set<String>,
        protectionReasons: [String: ADBTVInstalledAppProtectionReason],
        safetyCheckFailureDescription: String? = nil
    ) {
        self.userID = userID
        self.packages = packages
        self.disabledPackageNames = disabledPackageNames
        self.protectionReasons = protectionReasons
        self.safetyCheckFailureDescription = safetyCheckFailureDescription
    }

    public func state(for package: ADBTVInstalledPackage) -> ADBTVInstalledAppState {
        disabledPackageNames.contains(package.packageName) ? .disabled : .enabled
    }

    public func protectionReason(
        for package: ADBTVInstalledPackage
    ) -> ADBTVInstalledAppProtectionReason? {
        protectionReasons[package.packageName]
    }

    public var canDisablePackages: Bool {
        safetyCheckFailureDescription == nil
    }
}

public enum ADBTVInstalledAppKind: String, Equatable, Sendable {
    case user
    case system
}

public struct ADBTVActiveApp: Equatable, Identifiable, Sendable {
    public var id: String { package.packageName }
    public let package: ADBTVInstalledPackage
    public let kind: ADBTVInstalledAppKind
    public let isForeground: Bool
    public let memoryByteCount: Int64?
    public let processCount: Int

    public init(
        package: ADBTVInstalledPackage,
        kind: ADBTVInstalledAppKind,
        isForeground: Bool,
        memoryByteCount: Int64?,
        processCount: Int
    ) {
        self.package = package
        self.kind = kind
        self.isForeground = isForeground
        self.memoryByteCount = memoryByteCount
        self.processCount = processCount
    }
}

public struct ADBTVAppActivityDiagnostics: Equatable, Sendable {
    public let omittedProcessCount: Int
    public let missingMemoryProcessCount: Int
    public let invalidMemoryRowCount: Int
    public let unresolvedForegroundCount: Int

    public init(
        omittedProcessCount: Int = 0,
        missingMemoryProcessCount: Int = 0,
        invalidMemoryRowCount: Int = 0,
        unresolvedForegroundCount: Int = 0
    ) {
        self.omittedProcessCount = omittedProcessCount
        self.missingMemoryProcessCount = missingMemoryProcessCount
        self.invalidMemoryRowCount = invalidMemoryRowCount
        self.unresolvedForegroundCount = unresolvedForegroundCount
    }

    public var isPartial: Bool {
        omittedProcessCount > 0
            || missingMemoryProcessCount > 0
            || invalidMemoryRowCount > 0
            || unresolvedForegroundCount > 0
    }
}

public struct ADBTVAppActivitySnapshot: Equatable, Sendable {
    public let userID: Int
    public let apps: [ADBTVActiveApp]
    public let capturedAt: Date
    public let diagnostics: ADBTVAppActivityDiagnostics

    public init(
        userID: Int,
        apps: [ADBTVActiveApp],
        capturedAt: Date,
        diagnostics: ADBTVAppActivityDiagnostics = ADBTVAppActivityDiagnostics()
    ) {
        self.userID = userID
        self.apps = apps
        self.capturedAt = capturedAt
        self.diagnostics = diagnostics
    }
}

public struct ADBTVInstalledAppManager: Sendable {
    private static let androidUIDsPerUser = 100_000
    private static let detailsBatchSize = 16
    private static let maximumDetailsResponseByteCount = 1024 * 1024
    private static let maximumPackageListResponseByteCount = 256 * 1024
    private static let maximumProcessResponseByteCount = 1024 * 1024
    private static let maximumMemoryResponseByteCount = 2 * 1024 * 1024
    private static let maximumActivityResponseByteCount = 2 * 1024 * 1024
    private static let checkedShellAllowanceByteCount = 1024
    private static let maximumControlResponseByteCount = 4 * 1024
    private static let detailsProviderURI = "content://com.maxduke.adbtv.helper.v3.apps/apps"
    private static let fixedProtectionReasons: [String: ADBTVInstalledAppProtectionReason] = [
        "android": .androidCore,
        "com.android.shell": .androidCore,
        "com.android.systemui": .androidCore,
        "com.android.providers.settings": .androidCore,
        "com.android.networkstack": .androidCore,
        "com.android.packageinstaller": .androidCore,
        "com.google.android.packageinstaller": .androidCore,
        "com.google.android.permissioncontroller": .androidCore,
        "com.google.android.gms": .ecosystemInfrastructure,
        "com.google.android.gsf": .ecosystemInfrastructure,
        "com.android.vending": .ecosystemInfrastructure
    ]

    public init() {}

    public func list<Session: ADBShellCommandRunningSession>(
        scope: ADBTVInstalledAppScope = .user,
        using session: inout Session
    ) async throws -> [ADBTVInstalledPackage] {
        let flag = scope == .user ? "-3" : "-s"
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand("pm list packages \(flag)")
        )
        let output = try await session.runShellCommand(invocation.shellCommand)
        return try Self.parsePackages(try validatedPackageListOutput(
            invocation.validatedOutput(from: output)
        ))
    }

    public func activitySnapshot<Session: ADBDeviceToolsSession>(
        using session: inout Session,
        capturedAt: Date = Date()
    ) async throws -> ADBTVAppActivitySnapshot {
        let userID = try await boundedActiveUserID(using: &session)
        let userPackages = try await packageIdentities(
            kind: .user,
            userID: userID,
            using: &session
        )
        let systemPackages = try await packageIdentities(
            kind: .system,
            userID: userID,
            using: &session
        )
        let packages = try Self.mergePackageIdentities(userPackages, systemPackages)

        let processOutput = try await runBoundedChecked(
            "ps -A -w -o PID,UID,NAME",
            maximumOutputByteCount: Self.maximumProcessResponseByteCount,
            using: &session
        )
        let processResult = try Self.parseProcesses(processOutput)
        let attributedProcesses = Self.attributeProcesses(
            processResult.processes,
            to: packages,
            userID: userID
        )

        let memoryOutput = try await runBoundedChecked(
            "dumpsys meminfo -c",
            maximumOutputByteCount: Self.maximumMemoryResponseByteCount,
            using: &session
        )
        let memoryResult = try Self.parseMemory(memoryOutput)

        let activityOutput = try await runBoundedChecked(
            "dumpsys activity activities",
            maximumOutputByteCount: Self.maximumActivityResponseByteCount,
            using: &session
        )
        let foregroundResult = Self.parseForegroundPackages(
            activityOutput,
            userID: userID
        )

        let finalUserID = try await boundedActiveUserID(using: &session)
        guard finalUserID == userID else {
            throw ADBTVInstalledAppError.activeUserChanged(
                expected: userID,
                actual: finalUserID
            )
        }

        return Self.makeActivitySnapshot(
            userID: userID,
            packages: packages,
            processes: attributedProcesses.processes,
            processIssueCount: processResult.issueCount + attributedProcesses.issueCount,
            memoryResult: memoryResult,
            foregroundResult: foregroundResult,
            capturedAt: capturedAt
        )
    }

    public func systemSnapshot<Session: ADBShellCommandRunningSession>(
        using session: inout Session
    ) async throws -> ADBTVSystemAppSnapshot {
        let userID = try await activeUserID(using: &session)
        let packages = try await listSystemPackages(userID: userID, using: &session)
        let disabledPackages = try await listDisabledSystemPackages(
            userID: userID,
            using: &session
        )
        let packageNames = Set(packages.map(\.packageName))
        let disabledPackageNames = Set(disabledPackages.map(\.packageName))
            .intersection(packageNames)

        do {
            let protections = try await protectionReasons(
                userID: userID,
                using: &session
            ).filter { packageNames.contains($0.key) }
            return ADBTVSystemAppSnapshot(
                userID: userID,
                packages: packages,
                disabledPackageNames: disabledPackageNames,
                protectionReasons: protections
            )
        } catch {
            return ADBTVSystemAppSnapshot(
                userID: userID,
                packages: packages,
                disabledPackageNames: disabledPackageNames,
                protectionReasons: Self.fixedProtectionReasons.filter {
                    packageNames.contains($0.key)
                },
                safetyCheckFailureDescription: String(describing: error)
            )
        }
    }

    public func disable<Session: ADBShellCommandRunningSession>(
        _ package: ADBTVInstalledPackage,
        userID: Int,
        using session: inout Session
    ) async throws {
        try Self.validate(userID: userID)
        try await requireActiveUser(userID, using: &session)
        if let reason = Self.fixedProtectionReasons[package.packageName] {
            throw ADBTVInstalledAppError.protectedPackage(
                packageName: package.packageName,
                reason: reason
            )
        }
        if let reason = try await protectionReasons(
            userID: userID,
            using: &session
        )[package.packageName] {
            throw ADBTVInstalledAppError.protectedPackage(
                packageName: package.packageName,
                reason: reason
            )
        }
        _ = try await runChecked(
            "pm disable-user --user \(userID) \(package.shellEscaped)",
            using: &session
        )
        let state = try await state(for: package, userID: userID, using: &session)
        guard state == .disabled else {
            throw ADBTVInstalledAppError.packageStateMismatch(
                packageName: package.packageName,
                expected: .disabled,
                actual: state
            )
        }
    }

    public func restoreDefault<Session: ADBShellCommandRunningSession>(
        _ package: ADBTVInstalledPackage,
        userID: Int,
        using session: inout Session
    ) async throws -> ADBTVInstalledAppState {
        try Self.validate(userID: userID)
        try await requireActiveUser(userID, using: &session)
        _ = try await runChecked(
            "pm default-state --user \(userID) \(package.shellEscaped)",
            using: &session
        )
        return try await state(for: package, userID: userID, using: &session)
    }

    public func launch<Session: ADBShellCommandRunningSession>(
        _ package: ADBTVInstalledPackage,
        using session: inout Session
    ) async throws {
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand(
                "monkey -p \(package.shellEscaped) "
                    + "-c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1 "
                    + "|| monkey -p \(package.shellEscaped) "
                    + "-c android.intent.category.LAUNCHER 1"
            )
        )
        let output = try await session.runShellCommand(invocation.shellCommand)
        _ = try invocation.validatedOutput(from: output)
    }

    public func forceStop<Session: ADBShellCommandRunningSession>(
        _ package: ADBTVInstalledPackage,
        using session: inout Session
    ) async throws {
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand(
                "am force-stop --user current \(package.shellEscaped)"
            )
        )
        let output = try await session.runShellCommand(invocation.shellCommand)
        _ = try invocation.validatedOutput(from: output)
    }

    public func uninstall<Session: ADBShellCommandRunningSession>(
        _ package: ADBTVInstalledPackage,
        using session: inout Session
    ) async throws {
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand("pm uninstall \(package.shellEscaped)")
        )
        let output = try await session.runShellCommand(invocation.shellCommand)
        let result = try invocation.validatedOutput(from: output)
            .utf8String
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result == "Success" else {
            throw ADBTVInstalledAppError.unexpectedUninstallOutput(result)
        }
    }

    public func openAppSettings<Session: ADBShellCommandRunningSession>(
        _ package: ADBTVInstalledPackage,
        using session: inout Session
    ) async throws {
        let userID = try await activeUserID(using: &session)
        try await requireInstalledPackage(
            package,
            userID: userID,
            scope: nil,
            using: &session
        )
        try await requireActiveUser(userID, using: &session)
        let output = try await runChecked(
            "am start --user \(userID) -W "
                + "-a android.settings.APPLICATION_DETAILS_SETTINGS "
                + "-d 'package:\(package.packageName)'",
            using: &session
        )
        try Self.validateControlOutput(output)
    }

    public func clearData<Session: ADBShellCommandRunningSession>(
        _ package: ADBTVInstalledPackage,
        using session: inout Session
    ) async throws {
        let userID = try await activeUserID(using: &session)
        try await requireInstalledPackage(
            package,
            userID: userID,
            scope: .user,
            using: &session
        )
        try await requireActiveUser(userID, using: &session)
        let output = try await runChecked(
            "pm clear --user \(userID) \(package.shellEscaped)",
            using: &session
        )
        try Self.validateControlOutput(output)
        let result = output.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result == "Success" else {
            throw ADBTVInstalledAppError.unexpectedClearDataOutput(result)
        }
    }

    public func details<Session: ADBShellCommandRunningSession>(
        for packages: [ADBTVInstalledPackage],
        using session: inout Session
    ) async -> [String: ADBTVInstalledAppDetails] {
        var details: [String: ADBTVInstalledAppDetails] = [:]

        for startIndex in stride(from: 0, to: packages.count, by: Self.detailsBatchSize) {
            guard !Task.isCancelled else { break }
            let endIndex = min(startIndex + Self.detailsBatchSize, packages.count)
            let batch = Array(packages[startIndex ..< endIndex])
            guard let batchDetails = try? await loadDetailsBatch(batch, using: &session) else {
                break
            }
            guard !Task.isCancelled else { break }
            details.merge(batchDetails) { _, latest in latest }
        }
        return details
    }

    private func loadDetailsBatch<Session: ADBShellCommandRunningSession>(
        _ packages: [ADBTVInstalledPackage],
        using session: inout Session
    ) async throws -> [String: ADBTVInstalledAppDetails] {
        let packageQuery = packages.map(\.packageName).joined(separator: ",")
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand(
                "content read --uri '\(Self.detailsProviderURI)?packages=\(packageQuery)'"
            )
        )
        let output = try await session.runShellCommand(invocation.shellCommand)
        let validatedOutput = try invocation.validatedOutput(from: output)
        guard validatedOutput.bytes.count <= Self.maximumDetailsResponseByteCount else {
            throw ADBTVInstalledAppError.detailsResponseTooLarge(validatedOutput.bytes.count)
        }
        let response = try JSONDecoder().decode(
            [DetailsResponse].self,
            from: Data(validatedOutput.bytes)
        )
        let requestedPackages = Set(packages.map(\.packageName))
        var details: [String: ADBTVInstalledAppDetails] = [:]

        for item in response {
            guard requestedPackages.contains(item.package) else {
                continue
            }
            let icon = item.png
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { try? ADBTVInstalledAppIcon(pngData: $0) }
            details[item.package] = ADBTVInstalledAppDetails(
                displayName: item.label,
                versionName: item.versionName,
                versionCode: item.versionCode,
                firstInstallTimeMilliseconds: item.firstInstallTime,
                lastUpdateTimeMilliseconds: item.lastUpdateTime,
                apkByteCount: item.apkBytes,
                icon: icon,
                isStopped: item.stopped
            )
        }
        return details
    }

    private func activeUserID<Session: ADBShellCommandRunningSession>(
        using session: inout Session
    ) async throws -> Int {
        let output = try await runChecked("am get-current-user", using: &session)
        try Self.validateControlOutput(output)
        let userIDString = output
            .utf8String
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userIDString.isEmpty,
              userIDString.split(whereSeparator: { $0.isWhitespace }).count == 1,
              let userID = Int(userIDString) else {
            throw ADBTVInstalledAppError.invalidActiveUserID(userIDString)
        }
        try Self.validate(userID: userID)
        return userID
    }

    private func boundedActiveUserID<Session: ADBDeviceToolsSession>(
        using session: inout Session
    ) async throws -> Int {
        let output = try await runBoundedChecked(
            "am get-current-user",
            maximumOutputByteCount: Self.maximumControlResponseByteCount,
            using: &session
        )
        let value = output.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.split(whereSeparator: \.isWhitespace).count == 1,
              let userID = Int(value) else {
            throw ADBTVInstalledAppError.invalidActiveUserID(value)
        }
        try Self.validate(userID: userID)
        return userID
    }

    private func packageIdentities<Session: ADBDeviceToolsSession>(
        kind: ADBTVInstalledAppKind,
        userID: Int,
        using session: inout Session
    ) async throws -> [ADBTVAppPackageIdentity] {
        let flag = kind == .user ? "-3" : "-s"
        let output = try await runBoundedChecked(
            "pm list packages \(flag) -U --user \(userID)",
            maximumOutputByteCount: Self.maximumPackageListResponseByteCount,
            using: &session
        )
        return try Self.parsePackageIdentities(output, kind: kind, userID: userID)
    }

    private func runBoundedChecked<Session: ADBDeviceToolsSession>(
        _ command: String,
        maximumOutputByteCount: Int,
        using session: inout Session
    ) async throws -> ADBShellOutput {
        let invocation = try ADBCheckedShellInvocation(command: ADBShellCommand(command))
        let serviceLimit = maximumOutputByteCount.addingReportingOverflow(
            Self.checkedShellAllowanceByteCount
        )
        guard !serviceLimit.overflow else {
            throw ADBTVInstalledAppError.invalidActivityOutputLimit(maximumOutputByteCount)
        }
        let output = try await session.runService(
            invocation.shellCommand.serviceName,
            maximumOutputByteCount: serviceLimit.partialValue
        )
        let validated = try invocation.validatedOutput(
            from: ADBShellOutput(bytes: output.bytes)
        )
        guard validated.bytes.count <= maximumOutputByteCount else {
            throw ADBTVInstalledAppError.activityOutputTooLarge(
                command: command,
                byteCount: validated.bytes.count,
                maximumByteCount: maximumOutputByteCount
            )
        }
        return validated
    }

    private func requireActiveUser<Session: ADBShellCommandRunningSession>(
        _ expectedUserID: Int,
        using session: inout Session
    ) async throws {
        let actualUserID = try await activeUserID(using: &session)
        guard actualUserID == expectedUserID else {
            throw ADBTVInstalledAppError.activeUserChanged(
                expected: expectedUserID,
                actual: actualUserID
            )
        }
    }

    private func listSystemPackages<Session: ADBShellCommandRunningSession>(
        userID: Int,
        using session: inout Session
    ) async throws -> [ADBTVInstalledPackage] {
        try Self.validate(userID: userID)
        let output = try await runChecked(
            "pm list packages -s --user \(userID)",
            using: &session
        )
        return try Self.parsePackages(try validatedPackageListOutput(output))
    }

    private func requireInstalledPackage<Session: ADBShellCommandRunningSession>(
        _ package: ADBTVInstalledPackage,
        userID: Int,
        scope: ADBTVInstalledAppScope?,
        using session: inout Session
    ) async throws {
        try Self.validate(userID: userID)
        let flag = scope == .user ? " -3" : ""
        let output = try await runChecked(
            "pm list packages\(flag) --user \(userID) \(package.shellEscaped)",
            using: &session
        )
        let packages = try Self.parsePackages(try validatedPackageListOutput(output))
        guard packages.contains(package) else {
            if scope == .user {
                throw ADBTVInstalledAppError.packageNotUserInstalled(
                    packageName: package.packageName,
                    userID: userID
                )
            }
            throw ADBTVInstalledAppError.packageNotInstalled(
                packageName: package.packageName,
                userID: userID
            )
        }
    }

    private func listDisabledSystemPackages<Session: ADBShellCommandRunningSession>(
        userID: Int,
        using session: inout Session
    ) async throws -> [ADBTVInstalledPackage] {
        try Self.validate(userID: userID)
        let output = try await runChecked(
            "pm list packages -s -d --user \(userID)",
            using: &session
        )
        return try Self.parsePackages(try validatedPackageListOutput(output))
    }

    private func state<Session: ADBShellCommandRunningSession>(
        for package: ADBTVInstalledPackage,
        userID: Int,
        using session: inout Session
    ) async throws -> ADBTVInstalledAppState {
        let disabled = try await listDisabledSystemPackages(
            userID: userID,
            using: &session
        )
        return disabled.contains(package) ? .disabled : .enabled
    }

    private func protectionReasons<Session: ADBShellCommandRunningSession>(
        userID: Int,
        using session: inout Session
    ) async throws -> [String: ADBTVInstalledAppProtectionReason] {
        var reasons = Self.fixedProtectionReasons
        let launcher = try await resolvedPackage(
            "cmd package resolve-activity --brief --components --user \(userID) "
                + "-a android.intent.action.MAIN -c android.intent.category.HOME",
            using: &session
        )
        reasons[launcher.packageName] = .activeLauncher

        let settings = try await resolvedPackage(
            "cmd package resolve-activity --brief --components --user \(userID) "
                + "-a android.settings.SETTINGS",
            using: &session
        )
        reasons[settings.packageName] = .settings

        let inputMethodOutput = try await runChecked(
            "settings --user \(userID) get secure default_input_method",
            using: &session
        )
        try Self.validateControlOutput(inputMethodOutput)
        if let inputMethod = try Self.parseComponentPackage(
            inputMethodOutput,
            allowsNull: true
        ) {
            reasons[inputMethod.packageName] = .activeInputMethod
        }
        return reasons
    }

    private func resolvedPackage<Session: ADBShellCommandRunningSession>(
        _ command: String,
        using session: inout Session
    ) async throws -> ADBTVInstalledPackage {
        let output = try await runChecked(command, using: &session)
        try Self.validateControlOutput(output)
        guard let package = try Self.parseComponentPackage(output, allowsNull: false) else {
            throw ADBTVInstalledAppError.invalidComponentOutput(output.utf8String)
        }
        return package
    }

    private func runChecked<Session: ADBShellCommandRunningSession>(
        _ command: String,
        using session: inout Session
    ) async throws -> ADBShellOutput {
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand(command)
        )
        let output = try await session.runShellCommand(invocation.shellCommand)
        return try invocation.validatedOutput(from: output)
    }

    private func validatedPackageListOutput(
        _ output: ADBShellOutput
    ) throws -> ADBShellOutput {
        guard output.bytes.count <= Self.maximumPackageListResponseByteCount else {
            throw ADBTVInstalledAppError.packageListResponseTooLarge(output.bytes.count)
        }
        return output
    }

    private static func validate(userID: Int) throws {
        guard (0 ... Int(Int32.max)).contains(userID) else {
            throw ADBTVInstalledAppError.invalidUserID(userID)
        }
    }

    private static func validateControlOutput(_ output: ADBShellOutput) throws {
        guard output.bytes.count <= Self.maximumControlResponseByteCount else {
            throw ADBTVInstalledAppError.controlResponseTooLarge(output.bytes.count)
        }
    }

    private static func parseComponentPackage(
        _ output: ADBShellOutput,
        allowsNull: Bool
    ) throws -> ADBTVInstalledPackage? {
        let value = output.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowsNull, value == "null" {
            return nil
        }
        let components = value.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              components[1].unicodeScalars.allSatisfy(Self.isAllowedComponentScalar) else {
            throw ADBTVInstalledAppError.invalidComponentOutput(value)
        }
        return try ADBTVInstalledPackage(packageName: String(components[0]))
    }

    private static func isAllowedComponentScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 36, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
            return true
        default:
            return false
        }
    }

    private static func parsePackageIdentities(
        _ output: ADBShellOutput,
        kind: ADBTVInstalledAppKind,
        userID: Int
    ) throws -> [ADBTVAppPackageIdentity] {
        var packages: [String: ADBTVAppPackageIdentity] = [:]
        for rawLine in output.utf8String.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  fields[0].hasPrefix("package:"),
                  fields[1].hasPrefix("uid:") else {
                throw ADBTVInstalledAppError.invalidPackageUIDListLine(line)
            }

            let package = try ADBTVInstalledPackage(
                packageName: String(fields[0].dropFirst("package:".count))
            )
            let uidValue = fields[1].dropFirst("uid:".count)
            guard !uidValue.isEmpty,
                  uidValue.allSatisfy(\.isNumber),
                  let uid = Int(uidValue),
                  uid >= 0,
                  uid / Self.androidUIDsPerUser == userID else {
                throw ADBTVInstalledAppError.invalidPackageUIDListLine(line)
            }

            let identity = ADBTVAppPackageIdentity(
                package: package,
                kind: kind,
                uid: uid
            )
            if let existing = packages[package.packageName], existing != identity {
                throw ADBTVInstalledAppError.conflictingPackageUID(
                    packageName: package.packageName
                )
            }
            packages[package.packageName] = identity
        }
        return packages.values.sorted {
            $0.package.packageName < $1.package.packageName
        }
    }

    private static func mergePackageIdentities(
        _ userPackages: [ADBTVAppPackageIdentity],
        _ systemPackages: [ADBTVAppPackageIdentity]
    ) throws -> [String: ADBTVAppPackageIdentity] {
        var packages = Dictionary(
            uniqueKeysWithValues: userPackages.map { ($0.package.packageName, $0) }
        )
        for package in systemPackages {
            guard packages[package.package.packageName] == nil else {
                throw ADBTVInstalledAppError.duplicatePackageClassification(
                    packageName: package.package.packageName
                )
            }
            packages[package.package.packageName] = package
        }
        return packages
    }

    private static func parseProcesses(
        _ output: ADBShellOutput
    ) throws -> ADBTVProcessParseResult {
        let lines = output.utf8String.split(whereSeparator: \.isNewline)
        guard let header = lines.first,
              header.split(whereSeparator: \.isWhitespace).map(String.init)
                == ["PID", "UID", "NAME"] else {
            throw ADBTVInstalledAppError.invalidProcessListHeader(
                lines.first.map(String.init) ?? ""
            )
        }

        var processes: [Int: ADBTVProcessIdentity] = [:]
        var ambiguousPIDs = Set<Int>()
        var issueCount = 0
        for rawLine in lines.dropFirst() {
            let fields = rawLine.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                  let pid = Int(fields[0]),
                  pid > 0,
                  let uid = Int(fields[1]),
                  uid >= 0,
                  !fields[2].isEmpty else {
                issueCount += 1
                continue
            }

            let process = ADBTVProcessIdentity(
                pid: pid,
                uid: uid,
                name: String(fields[2])
            )
            guard !ambiguousPIDs.contains(pid) else {
                continue
            }
            if let existing = processes[pid] {
                if existing != process {
                    processes.removeValue(forKey: pid)
                    ambiguousPIDs.insert(pid)
                    issueCount += 1
                }
            } else {
                processes[pid] = process
            }
        }
        return ADBTVProcessParseResult(
            processes: Array(processes.values),
            issueCount: issueCount
        )
    }

    private static func attributeProcesses(
        _ processes: [ADBTVProcessIdentity],
        to packages: [String: ADBTVAppPackageIdentity],
        userID: Int
    ) -> ADBTVAttributedProcessResult {
        let sharedUIDs = Set(
            Dictionary(grouping: packages.values, by: \.uid)
                .filter { $0.value.count > 1 }
                .map { $0.key }
        )
        var attributed: [ADBTVAttributedProcess] = []
        var issueCount = 0

        for process in processes {
            let nameParts = process.name.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let packageName = nameParts.first.map(String.init) ?? ""
            guard let package = packages[packageName] else {
                continue
            }
            guard nameParts.count == 1 || !nameParts[1].isEmpty,
                  process.uid / Self.androidUIDsPerUser == userID,
                  process.uid == package.uid,
                  !sharedUIDs.contains(process.uid) else {
                issueCount += 1
                continue
            }
            attributed.append(ADBTVAttributedProcess(
                pid: process.pid,
                name: process.name,
                packageName: packageName
            ))
        }
        return ADBTVAttributedProcessResult(
            processes: attributed,
            issueCount: issueCount
        )
    }

    private static func parseMemory(
        _ output: ADBShellOutput
    ) throws -> ADBTVMemoryParseResult {
        var sawVersion = false
        var values: [ADBTVProcessMemoryKey: Int64] = [:]
        var ambiguousKeys = Set<ADBTVProcessMemoryKey>()
        var issueCount = 0

        for rawLine in output.utf8String.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(
                separator: ",",
                omittingEmptySubsequences: false
            )
            if fields.first == "version" {
                guard !sawVersion, fields.count == 2, fields[1] == "1" else {
                    throw ADBTVInstalledAppError.invalidCompactMemoryVersion(
                        String(rawLine)
                    )
                }
                sawVersion = true
                continue
            }
            guard fields.first == "proc" else {
                continue
            }
            guard fields.count == 7,
                  !fields[2].isEmpty,
                  let pid = Int(fields[3]),
                  pid > 0,
                  let pssKiB = Int64(fields[4]),
                  pssKiB >= 0 else {
                issueCount += 1
                continue
            }

            let key = ADBTVProcessMemoryKey(pid: pid, name: String(fields[2]))
            guard !ambiguousKeys.contains(key) else {
                continue
            }
            if let existing = values[key] {
                if existing != pssKiB {
                    values.removeValue(forKey: key)
                    ambiguousKeys.insert(key)
                    issueCount += 1
                }
            } else {
                values[key] = pssKiB
            }
        }
        guard sawVersion else {
            throw ADBTVInstalledAppError.invalidCompactMemoryVersion("")
        }
        return ADBTVMemoryParseResult(values: values, issueCount: issueCount)
    }

    private static func parseForegroundPackages(
        _ output: ADBShellOutput,
        userID: Int
    ) -> ADBTVForegroundParseResult {
        let markers = ["mResumedActivity:", "ResumedActivity:"]
        let punctuation = CharacterSet(charactersIn: "{}[](),")
        var packages = Set<String>()
        var issueCount = 0

        for rawLine in output.utf8String.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let marker = markers.first(where: { line.contains($0) }),
                  let markerRange = line.range(of: marker) else {
                continue
            }
            let suffix = String(line[markerRange.upperBound...])
            if suffix.trimmingCharacters(in: .whitespaces).hasPrefix("null") {
                continue
            }

            var parsedUserID: Int?
            var package: ADBTVInstalledPackage?
            for rawToken in suffix.split(whereSeparator: \.isWhitespace) {
                let token = String(rawToken).trimmingCharacters(in: punctuation)
                if token.first == "u" {
                    let value = token.dropFirst()
                    if !value.isEmpty, value.allSatisfy(\.isNumber) {
                        parsedUserID = Int(value)
                    }
                }
                if let slash = token.firstIndex(of: "/") {
                    package = try? ADBTVInstalledPackage(
                        packageName: String(token[..<slash])
                    )
                }
            }

            guard let parsedUserID, let package else {
                issueCount += 1
                continue
            }
            if parsedUserID == userID {
                packages.insert(package.packageName)
            }
        }
        return ADBTVForegroundParseResult(
            packageNames: packages,
            issueCount: issueCount
        )
    }

    private static func makeActivitySnapshot(
        userID: Int,
        packages: [String: ADBTVAppPackageIdentity],
        processes: [ADBTVAttributedProcess],
        processIssueCount: Int,
        memoryResult: ADBTVMemoryParseResult,
        foregroundResult: ADBTVForegroundParseResult,
        capturedAt: Date
    ) -> ADBTVAppActivitySnapshot {
        let grouped = Dictionary(grouping: processes, by: \.packageName)
        let activePackageNames = Set(grouped.keys)
        var missingMemoryProcessCount = 0
        var invalidMemoryRowCount = memoryResult.issueCount
        var apps: [ADBTVActiveApp] = []

        for (packageName, packageProcesses) in grouped {
            guard let identity = packages[packageName] else {
                continue
            }
            var totalBytes: Int64 = 0
            var hasCompleteMemory = true
            for process in packageProcesses {
                let key = ADBTVProcessMemoryKey(pid: process.pid, name: process.name)
                guard let pssKiB = memoryResult.values[key] else {
                    missingMemoryProcessCount += 1
                    hasCompleteMemory = false
                    continue
                }
                let bytes = pssKiB.multipliedReportingOverflow(by: 1024)
                let total = totalBytes.addingReportingOverflow(bytes.partialValue)
                guard !bytes.overflow, !total.overflow else {
                    invalidMemoryRowCount += 1
                    hasCompleteMemory = false
                    continue
                }
                totalBytes = total.partialValue
            }

            apps.append(ADBTVActiveApp(
                package: identity.package,
                kind: identity.kind,
                isForeground: foregroundResult.packageNames.contains(packageName),
                memoryByteCount: hasCompleteMemory ? totalBytes : nil,
                processCount: packageProcesses.count
            ))
        }

        apps.sort {
            if $0.isForeground != $1.isForeground {
                return $0.isForeground
            }
            switch ($0.memoryByteCount, $1.memoryByteCount) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs > rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return $0.package.packageName < $1.package.packageName
            }
        }

        let unresolvedForegroundCount = foregroundResult.issueCount
            + foregroundResult.packageNames.subtracting(activePackageNames).count
        return ADBTVAppActivitySnapshot(
            userID: userID,
            apps: apps,
            capturedAt: capturedAt,
            diagnostics: ADBTVAppActivityDiagnostics(
                omittedProcessCount: processIssueCount,
                missingMemoryProcessCount: missingMemoryProcessCount,
                invalidMemoryRowCount: invalidMemoryRowCount,
                unresolvedForegroundCount: unresolvedForegroundCount
            )
        )
    }

    private static func parsePackages(
        _ output: ADBShellOutput
    ) throws -> [ADBTVInstalledPackage] {
        var packages = Set<ADBTVInstalledPackage>()
        for rawLine in output.utf8String.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("package:") else {
                throw ADBTVInstalledAppError.invalidPackageListLine(line)
            }
            packages.insert(try ADBTVInstalledPackage(
                packageName: String(line.dropFirst("package:".count))
            ))
        }
        return packages.sorted { $0.packageName < $1.packageName }
    }
}

private struct ADBTVAppPackageIdentity: Equatable {
    let package: ADBTVInstalledPackage
    let kind: ADBTVInstalledAppKind
    let uid: Int
}

private struct ADBTVProcessIdentity: Equatable {
    let pid: Int
    let uid: Int
    let name: String
}

private struct ADBTVProcessParseResult {
    let processes: [ADBTVProcessIdentity]
    let issueCount: Int
}

private struct ADBTVAttributedProcess {
    let pid: Int
    let name: String
    let packageName: String
}

private struct ADBTVAttributedProcessResult {
    let processes: [ADBTVAttributedProcess]
    let issueCount: Int
}

private struct ADBTVProcessMemoryKey: Hashable {
    let pid: Int
    let name: String
}

private struct ADBTVMemoryParseResult {
    let values: [ADBTVProcessMemoryKey: Int64]
    let issueCount: Int
}

private struct ADBTVForegroundParseResult {
    let packageNames: Set<String>
    let issueCount: Int
}

private struct DetailsResponse: Decodable {
    let package: String
    let label: String?
    let versionName: String?
    let versionCode: Int64?
    let firstInstallTime: Int64?
    let lastUpdateTime: Int64?
    let apkBytes: Int64?
    let png: String?
    let stopped: Bool?
}

public enum ADBTVInstalledAppError: Error, Equatable, Sendable {
    case invalidPackageName(String)
    case invalidPackageListLine(String)
    case invalidActiveUserID(String)
    case invalidUserID(Int)
    case activeUserChanged(expected: Int, actual: Int)
    case packageNotInstalled(packageName: String, userID: Int)
    case packageNotUserInstalled(packageName: String, userID: Int)
    case invalidComponentOutput(String)
    case packageListResponseTooLarge(Int)
    case controlResponseTooLarge(Int)
    case protectedPackage(
        packageName: String,
        reason: ADBTVInstalledAppProtectionReason
    )
    case packageStateMismatch(
        packageName: String,
        expected: ADBTVInstalledAppState,
        actual: ADBTVInstalledAppState
    )
    case unexpectedUninstallOutput(String)
    case unexpectedClearDataOutput(String)
    case iconPNGTooLarge(Int)
    case invalidIconPNG
    case invalidIconDimensions(width: Int, height: Int)
    case detailsResponseTooLarge(Int)
    case invalidPackageUIDListLine(String)
    case conflictingPackageUID(packageName: String)
    case duplicatePackageClassification(packageName: String)
    case invalidProcessListHeader(String)
    case invalidCompactMemoryVersion(String)
    case invalidActivityOutputLimit(Int)
    case activityOutputTooLarge(
        command: String,
        byteCount: Int,
        maximumByteCount: Int
    )
}
