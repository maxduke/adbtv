import Foundation

public struct ADBTVInstalledPackage: Hashable, Identifiable, Sendable {
    public var id: String { packageName }
    public var packageName: String

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

public struct ADBTVInstalledAppManager: Sendable {
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

public enum ADBTVInstalledAppError: Error, Equatable, Sendable {
    case invalidPackageName(String)
    case invalidPackageListLine(String)
    case unexpectedUninstallOutput(String)
}
