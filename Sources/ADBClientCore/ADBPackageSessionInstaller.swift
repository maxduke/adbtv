import Foundation

public struct ADBPackageSessionFile: Equatable, Sendable {
    public let fileURL: URL
    public let fileName: String
    public let byteCount: Int64

    public init(fileURL: URL, fileName: String, byteCount: Int64) throws {
        _ = try ADBInstallPackage(fileName: fileName, byteCount: byteCount)
        guard byteCount > 0 else {
            throw ADBPackageSessionInstallError.emptyPackage(fileName)
        }
        self.fileURL = fileURL
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

public protocol ADBPackageSessionRunning: Sendable {
    mutating func runService(
        _ service: String,
        maximumOutputByteCount: Int
    ) async throws -> ADBServiceOutput

    mutating func runService(
        _ service: String,
        inputFrom fileURL: URL,
        inputByteCount: Int64,
        maximumOutputByteCount: Int,
        progressHandler: @escaping @Sendable (Int64) async -> Void
    ) async throws -> ADBServiceOutput
}

extension ADBDeviceSession: ADBPackageSessionRunning {}
#if canImport(Network)
extension ADBDeviceConnection: ADBPackageSessionRunning {}
#endif

public enum ADBPackageSessionInstallEvent: Equatable, Sendable {
    case sessionCreated(id: Int)
    case transferProgress(fileName: String, sentByteCount: Int64, totalByteCount: Int64)
    case committing
    case installResult(ADBAPKInstallResult)
    case abandoning(id: Int)
}

public typealias ADBPackageSessionInstallEventHandler = @Sendable (
    ADBPackageSessionInstallEvent
) async -> Void

public struct ADBPackageSessionInstaller: Sendable {
    public static let maximumCommandOutputByteCount = 64 * 1024

    public init() {}

    public func install<Session: ADBPackageSessionRunning>(
        files: [ADBPackageSessionFile],
        using session: inout Session,
        eventHandler: @escaping ADBPackageSessionInstallEventHandler = { _ in }
    ) async throws -> ADBAPKInstallResult {
        try Task.checkCancellation()
        guard !files.isEmpty else {
            throw ADBPackageSessionInstallError.missingPackages
        }
        let totalByteCount = try files.reduce(Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.byteCount)
            guard !overflow else {
                throw ADBPackageSessionInstallError.packageSizeOverflow
            }
            return sum
        }

        var sessionID: Int?
        do {
            let createOutput = try await session.runService(
                "exec:cmd package install-create -r -S \(totalByteCount)",
                maximumOutputByteCount: Self.maximumCommandOutputByteCount
            )
            let createdSessionID = try Self.parseSessionID(createOutput.utf8String)
            sessionID = createdSessionID
            await eventHandler(.sessionCreated(id: createdSessionID))

            var transferredByteCount: Int64 = 0
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let transferredBeforeFile = transferredByteCount
                let output = try await session.runService(
                    "exec:cmd package install-write -S \(file.byteCount) \(createdSessionID) \(Self.sessionFileName(index: index, file: file)) -",
                    inputFrom: file.fileURL,
                    inputByteCount: file.byteCount,
                    maximumOutputByteCount: Self.maximumCommandOutputByteCount,
                    progressHandler: { sentByteCount in
                        await eventHandler(.transferProgress(
                            fileName: file.fileName,
                            sentByteCount: transferredBeforeFile + sentByteCount,
                            totalByteCount: totalByteCount
                        ))
                    }
                )
                try Self.requireSuccess(output, phase: "install-write", fileName: file.fileName)
                transferredByteCount += file.byteCount
            }

            try Task.checkCancellation()
            await eventHandler(.committing)
            let commitOutput = try await session.runService(
                "exec:cmd package install-commit \(createdSessionID)",
                maximumOutputByteCount: Self.maximumCommandOutputByteCount
            )
            let result = ADBAPKInstallResult.parse(output: commitOutput.utf8String)
            await eventHandler(.installResult(result))
            sessionID = nil
            return result
        } catch {
            let abandonError: String?
            if let sessionID {
                abandonError = await abandon(
                    id: sessionID,
                    using: &session,
                    eventHandler: eventHandler
                )
            } else {
                abandonError = nil
            }
            if error is CancellationError {
                throw ADBPackageSessionInstallCancellationError(abandonError: abandonError)
            }
            throw ADBPackageSessionInstallError.operationFailed(
                underlyingError: String(describing: error),
                abandonError: abandonError
            )
        }
    }

    public func abandon<Session: ADBPackageSessionRunning>(
        id: Int,
        using session: inout Session,
        eventHandler: @escaping ADBPackageSessionInstallEventHandler = { _ in }
    ) async -> String? {
        await eventHandler(.abandoning(id: id))
        do {
            let output = try await session.runService(
                "exec:cmd package install-abandon \(id)",
                maximumOutputByteCount: Self.maximumCommandOutputByteCount
            )
            try Self.requireSuccess(output, phase: "install-abandon")
            return nil
        } catch {
            return String(describing: error)
        }
    }

    static func parseSessionID(_ output: String) throws -> Int {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Success"),
              let openingBracket = trimmed.lastIndex(of: "["),
              let closingBracket = trimmed.lastIndex(of: "]"),
              openingBracket < closingBracket,
              let sessionID = Int(trimmed[trimmed.index(after: openingBracket)..<closingBracket]),
              sessionID >= 0 else {
            throw ADBPackageSessionInstallError.invalidCreateOutput(trimmed)
        }
        return sessionID
    }

    private static func sessionFileName(index: Int, file: ADBPackageSessionFile) -> String {
        file.fileName.lowercased() == "base.apk" ? "base.apk" : "split_\(index).apk"
    }

    private static func requireSuccess(
        _ output: ADBServiceOutput,
        phase: String,
        fileName: String? = nil
    ) throws {
        let text = output.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("Success") else {
            throw ADBPackageSessionInstallError.commandFailed(
                phase: phase,
                fileName: fileName,
                output: text
            )
        }
    }
}

public struct ADBPackageSessionInstallCancellationError: Error, Equatable, Sendable {
    public let abandonError: String?

    public init(abandonError: String?) {
        self.abandonError = abandonError
    }
}

public enum ADBPackageSessionInstallError: Error, Equatable, Sendable {
    case missingPackages
    case emptyPackage(String)
    case packageSizeOverflow
    case invalidCreateOutput(String)
    case commandFailed(phase: String, fileName: String?, output: String)
    case operationFailed(underlyingError: String, abandonError: String?)
}
