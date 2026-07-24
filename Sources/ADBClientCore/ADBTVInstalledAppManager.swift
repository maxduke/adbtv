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

public struct ADBTVInstalledAppManager: Sendable {
    private static let detailsBatchSize = 16
    private static let maximumDetailsCount = 128
    private static let maximumDetailsResponseByteCount = 1024 * 1024
    private static let detailsProviderURI = "content://com.maxduke.adbtv.helper.v3.apps/apps"

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
        return try Self.parsePackages(invocation.validatedOutput(from: output))
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
    case unexpectedUninstallOutput(String)
    case iconPNGTooLarge(Int)
    case invalidIconPNG
    case invalidIconDimensions(width: Int, height: Int)
    case detailsResponseTooLarge(Int)
}
