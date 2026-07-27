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

public struct ADBTVInstalledAppManager: Sendable {
    private static let detailsBatchSize = 16
    private static let maximumDetailsCount = 128
    private static let maximumDetailsResponseByteCount = 1024 * 1024
    private static let maximumPackageListResponseByteCount = 256 * 1024
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

    public func details<Session: ADBShellCommandRunningSession>(
        for packages: [ADBTVInstalledPackage],
        using session: inout Session
    ) async -> [String: ADBTVInstalledAppDetails] {
        // ponytail: cap helper work; raise only if real TV package lists need more metadata.
        let packages = Array(packages.prefix(Self.maximumDetailsCount))
        var details: [String: ADBTVInstalledAppDetails] = [:]

        for startIndex in stride(from: 0, to: packages.count, by: Self.detailsBatchSize) {
            let endIndex = min(startIndex + Self.detailsBatchSize, packages.count)
            let batch = Array(packages[startIndex ..< endIndex])
            guard let batchDetails = try? await loadDetailsBatch(batch, using: &session) else {
                break
            }
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
    case iconPNGTooLarge(Int)
    case invalidIconPNG
    case invalidIconDimensions(width: Int, height: Int)
    case detailsResponseTooLarge(Int)
}
