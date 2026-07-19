import Foundation

public struct ADBAPKInstallPlan: Equatable, Sendable {
    public var package: ADBInstallPackage
    public var remoteAPKPath: ADBRemotePath
    public var options: ADBAPKInstallOptions

    public init(
        package: ADBInstallPackage,
        remoteAPKPath: ADBRemotePath,
        options: ADBAPKInstallOptions = ADBAPKInstallOptions()
    ) {
        self.package = package
        self.remoteAPKPath = remoteAPKPath
        self.options = options
    }

    public static func singleAPK(
        fileName: String,
        byteCount: Int64? = nil,
        remoteDirectory: ADBRemotePath = ADBRemotePath.temporaryInstallDirectory,
        stagingIdentifier: UUID = UUID(),
        options: ADBAPKInstallOptions = ADBAPKInstallOptions()
    ) throws -> ADBAPKInstallPlan {
        let package = try ADBInstallPackage(fileName: fileName, byteCount: byteCount)
        let remoteFileName = stagingIdentifier.uuidString.lowercased() + ".apk"
        let remotePath = try remoteDirectory.appendingPathComponent(remoteFileName)
        return ADBAPKInstallPlan(package: package, remoteAPKPath: remotePath, options: options)
    }

    public var phases: [ADBAPKInstallPhase] {
        [.validatePackage, .prepareRemoteDirectory, .transferPackage, .installPackage, .cleanup]
    }

    public func prepareRemoteDirectoryShellCommand() throws -> ADBShellCommand {
        try ADBShellCommand(
            "mkdir -p \(remoteAPKPath.parentDirectory.shellEscaped) && \(verifiedRemovalShellCommand)"
        )
    }

    public func prepareRemoteDirectoryShellInvocation() throws -> ADBCheckedShellInvocation {
        try ADBCheckedShellInvocation(command: prepareRemoteDirectoryShellCommand())
    }

    public func installShellCommand() throws -> ADBShellCommand {
        try ADBShellCommand((["pm", "install"] + options.arguments + [remoteAPKPath.shellEscaped]).joined(separator: " "))
    }

    public func cleanupShellCommand() throws -> ADBShellCommand {
        try ADBShellCommand(verifiedRemovalShellCommand)
    }

    public func cleanupShellInvocation() throws -> ADBCheckedShellInvocation {
        try ADBCheckedShellInvocation(command: cleanupShellCommand())
    }

    private var verifiedRemovalShellCommand: String {
        "rm -f \(remoteAPKPath.shellEscaped) && test ! -e \(remoteAPKPath.shellEscaped)"
    }
}

public struct ADBInstallPackage: Equatable, Sendable {
    public var fileName: String
    public var byteCount: Int64?

    public init(fileName: String, byteCount: Int64? = nil) throws {
        guard fileName.lowercased().hasSuffix(".apk") else {
            throw ADBInstallPackageError.unsupportedFileExtension
        }

        guard !fileName.contains("/") && !fileName.contains("\\") else {
            throw ADBInstallPackageError.pathSeparatorInFileName
        }

        guard !fileName.utf8.contains(0) else {
            throw ADBInstallPackageError.containsNullByte
        }

        guard byteCount.map({ $0 >= 0 }) ?? true else {
            throw ADBInstallPackageError.negativeByteCount
        }

        self.fileName = fileName
        self.byteCount = byteCount
    }

}

public enum ADBInstallPackageError: Error, Equatable, Sendable {
    case unsupportedFileExtension
    case pathSeparatorInFileName
    case containsNullByte
    case negativeByteCount
}

public struct ADBRemotePath: Equatable, Sendable {
    public static let temporaryInstallDirectory = ADBRemotePath(unchecked: "/data/local/tmp/adbtv")
    public static let sharedStorageDirectory = ADBRemotePath(unchecked: "/sdcard")

    public var rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.hasPrefix("/") else {
            throw ADBRemotePathError.notAbsolute
        }

        guard !rawValue.utf8.contains(0) else {
            throw ADBRemotePathError.containsNullByte
        }

        guard !rawValue.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw ADBRemotePathError.containsNewline
        }

        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public func appendingPathComponent(_ component: String) throws -> ADBRemotePath {
        guard !component.isEmpty else {
            throw ADBRemotePathError.emptyPathComponent
        }

        guard component != "." && component != ".." else {
            throw ADBRemotePathError.relativePathComponent
        }

        guard !component.contains("/") && !component.contains("\\") else {
            throw ADBRemotePathError.pathSeparatorInComponent
        }

        let separator = rawValue.hasSuffix("/") ? "" : "/"
        return try ADBRemotePath("\(rawValue)\(separator)\(component)")
    }

    public var parentDirectory: ADBRemotePath {
        guard rawValue != "/" else {
            return self
        }

        let trimmedPath = rawValue.hasSuffix("/") ? String(rawValue.dropLast()) : rawValue
        guard let separatorIndex = trimmedPath.lastIndex(of: "/") else {
            return Self.temporaryInstallDirectory
        }

        if separatorIndex == trimmedPath.startIndex {
            return ADBRemotePath(unchecked: "/")
        }

        return ADBRemotePath(unchecked: String(trimmedPath[..<separatorIndex]))
    }

    public var shellEscaped: String {
        "'\(rawValue.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public enum ADBRemotePathError: Error, Equatable, Sendable {
    case notAbsolute
    case containsNullByte
    case containsNewline
    case emptyPathComponent
    case relativePathComponent
    case pathSeparatorInComponent
}

public struct ADBAPKInstallOptions: Equatable, Sendable {
    public var replaceExisting: Bool

    public init(replaceExisting: Bool = true) {
        self.replaceExisting = replaceExisting
    }

    public var arguments: [String] {
        replaceExisting ? ["-r"] : []
    }
}

public enum ADBAPKInstallPhase: Equatable, Sendable {
    case validatePackage
    case prepareRemoteDirectory
    case transferPackage
    case installPackage
    case cleanup
}

public enum ADBAPKInstallResult: Equatable, Sendable {
    case success
    case failure(message: String)

    public var isUpdateIncompatible: Bool {
        guard case .failure(let message) = self else {
            return false
        }
        return message.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE")
    }

    public static func parse(shellOutput: ADBShellOutput) -> ADBAPKInstallResult {
        parse(output: shellOutput.utf8String)
    }

    public static func parse(output: String) -> ADBAPKInstallResult {
        let normalizedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedOutput != "Success" else {
            return .success
        }

        if let failureMessage = bracketedMessage(prefix: "Failure", in: normalizedOutput) {
            return .failure(message: failureMessage)
        }

        if let errorLine = normalizedOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix("Error:") }) {
            return .failure(message: errorLine)
        }

        return .failure(message: normalizedOutput.isEmpty ? "Unknown install failure" : normalizedOutput)
    }

    private static func bracketedMessage(prefix: String, in output: String) -> String? {
        guard output.hasPrefix("\(prefix) ["), output.hasSuffix("]") else {
            return nil
        }

        let start = output.index(output.startIndex, offsetBy: prefix.count + 2)
        let end = output.index(before: output.endIndex)
        return String(output[start..<end])
    }
}
