import ADBClientCore
import Foundation

public protocol ADBTVAPKInstallConnection: Sendable {
    mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32
    ) async throws -> ADBAPKInstallReport
}

#if canImport(Network)
extension ADBDeviceConnection: ADBTVAPKInstallConnection {
    public mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32
    ) async throws -> ADBAPKInstallReport {
        try await installAPK(
            contents: contents,
            plan: plan,
            modificationTime: modificationTime,
            installer: ADBAPKInstaller()
        )
    }
}
#endif

public struct ADBTVInstallOperation: Sendable {
    public var readFile: @Sendable (URL) throws -> [UInt8]
    public var modificationTime: @Sendable () -> UInt32

    public init(
        readFile: @escaping @Sendable (URL) throws -> [UInt8] = {
            try ADBTVInstallFileReader.readFileBytes(from: $0)
        },
        modificationTime: @escaping @Sendable () -> UInt32 = {
            UInt32(Date().timeIntervalSince1970)
        }
    ) {
        self.readFile = readFile
        self.modificationTime = modificationTime
    }

    public func installSelectedPackage<Connection: ADBTVAPKInstallConnection>(
        from model: ADBTVAppModel,
        using connection: inout Connection
    ) async throws -> ADBAPKInstallReport {
        guard model.selectedDevice != nil else {
            throw ADBTVInstallOperationError.missingDevice
        }

        guard let selectedPackage = model.installDraft.selectedPackage else {
            throw ADBTVInstallOperationError.missingPackage
        }

        guard let fileURL = selectedPackage.fileURL else {
            throw ADBTVInstallOperationError.missingPackageFile
        }

        let contents = try readFile(fileURL)
        let plan = try model.installDraft.installPlan()
        return try await connection.installAPK(
            contents: contents,
            plan: plan,
            modificationTime: modificationTime()
        )
    }
}

public enum ADBTVInstallFileReader: Sendable {
    public static func readFileBytes(from url: URL) throws -> [UInt8] {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return Array(try Data(contentsOf: url))
    }
}

public enum ADBTVInstallOperationError: Error, Equatable, Sendable {
    case missingDevice
    case missingPackage
    case missingPackageFile
    case invalidDevicePort(Int)
    case unsupportedPlatform
}
