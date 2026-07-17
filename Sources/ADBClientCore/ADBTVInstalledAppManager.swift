import Foundation

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

public struct ADBTVInstalledAppManager: Sendable {
    private static let iconBatchSize = 16
    private static let maximumIconCount = 128
    private static let maximumIconResponseByteCount = 1024 * 1024
    private static let iconProviderURI = "content://com.maxduke.adbtv.helper.v2.icons/icons"

    public init() {}

    public func list<Session: ADBShellCommandRunningSession>(
        using session: inout Session
    ) async throws -> [ADBTVInstalledPackage] {
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand("pm list packages -3")
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

    public func icons<Session: ADBShellCommandRunningSession>(
        for packages: [ADBTVInstalledPackage],
        using session: inout Session
    ) async -> [String: ADBTVInstalledAppIcon] {
        // ponytail: cap icon work; raise only if real TV libraries exceed 128 user apps.
        let packages = Array(packages.prefix(Self.maximumIconCount))
        var icons: [String: ADBTVInstalledAppIcon] = [:]

        for startIndex in stride(from: 0, to: packages.count, by: Self.iconBatchSize) {
            let endIndex = min(startIndex + Self.iconBatchSize, packages.count)
            let batch = Array(packages[startIndex ..< endIndex])
            guard let batchIcons = try? await loadIconBatch(batch, using: &session) else {
                break
            }
            icons.merge(batchIcons) { _, latest in latest }
        }
        return icons
    }

    private func loadIconBatch<Session: ADBShellCommandRunningSession>(
        _ packages: [ADBTVInstalledPackage],
        using session: inout Session
    ) async throws -> [String: ADBTVInstalledAppIcon] {
        let packageQuery = packages.map(\.packageName).joined(separator: ",")
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand(
                "content read --uri '\(Self.iconProviderURI)?packages=\(packageQuery)' "
                    + "2>/dev/null | head -c \(Self.maximumIconResponseByteCount)"
            )
        )
        let output = try await session.runShellCommand(invocation.shellCommand)
        let response = try JSONDecoder().decode(
            [IconResponse].self,
            from: Data(invocation.validatedOutput(from: output).bytes)
        )
        let requestedPackages = Set(packages.map(\.packageName))
        var icons: [String: ADBTVInstalledAppIcon] = [:]

        for item in response {
            guard requestedPackages.contains(item.package),
                  let data = Data(base64Encoded: item.png),
                  let icon = try? ADBTVInstalledAppIcon(pngData: data) else {
                continue
            }
            icons[item.package] = icon
        }
        return icons
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

private struct IconResponse: Decodable {
    let package: String
    let png: String
}

public enum ADBTVInstalledAppError: Error, Equatable, Sendable {
    case invalidPackageName(String)
    case invalidPackageListLine(String)
    case unexpectedUninstallOutput(String)
    case iconPNGTooLarge(Int)
    case invalidIconPNG
    case invalidIconDimensions(width: Int, height: Int)
}
