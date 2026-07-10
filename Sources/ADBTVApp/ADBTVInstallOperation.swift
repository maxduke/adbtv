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
    public var downloadPackage: @Sendable (URL) async throws -> ADBTVDownloadedPackage
    public var modificationTime: @Sendable () -> UInt32

    public init(
        readFile: @escaping @Sendable (URL) throws -> [UInt8] = {
            try ADBTVInstallFileReader.readFileBytes(from: $0)
        },
        downloadPackage: @escaping @Sendable (URL) async throws -> ADBTVDownloadedPackage = {
            try await ADBTVInstallDownloader.downloadPackage(from: $0)
        },
        modificationTime: @escaping @Sendable () -> UInt32 = {
            UInt32(Date().timeIntervalSince1970)
        }
    ) {
        self.readFile = readFile
        self.downloadPackage = downloadPackage
        self.modificationTime = modificationTime
    }

    public func installSelectedPackage<Connection: ADBTVAPKInstallConnection>(
        from model: ADBTVAppModel,
        using connection: inout Connection
    ) async throws -> ADBAPKInstallReport {
        guard model.selectedDevice != nil else {
            throw ADBTVInstallOperationError.missingDevice
        }

        let payload = try await installPayload(from: model.installDraft)
        return try await connection.installAPK(
            contents: payload.contents,
            plan: payload.plan,
            modificationTime: modificationTime()
        )
    }

    private func installPayload(from draft: ADBTVInstallDraft) async throws -> InstallPayload {
        if let selectedPackage = draft.selectedPackage {
            guard let fileURL = selectedPackage.fileURL else {
                throw ADBTVInstallOperationError.missingPackageFile
            }

            return try InstallPayload(
                contents: readFile(fileURL),
                plan: draft.installPlan()
            )
        }

        guard let url = draft.validatedURL,
              let fileName = draft.urlFileName else {
            throw ADBTVInstallOperationError.missingPackage
        }

        let downloadedPackage = try await downloadPackage(url)
        return try InstallPayload(
            contents: downloadedPackage.contents,
            plan: ADBAPKInstallPlan.singleAPK(
                fileName: downloadedPackage.fileName ?? fileName,
                byteCount: Int64(downloadedPackage.contents.count)
            )
        )
    }
}

private struct InstallPayload: Sendable {
    var contents: [UInt8]
    var plan: ADBAPKInstallPlan
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

public struct ADBTVDownloadedPackage: Equatable, Sendable {
    public var contents: [UInt8]
    public var fileName: String?

    public init(contents: [UInt8], fileName: String? = nil) {
        self.contents = contents
        self.fileName = fileName
    }
}

public enum ADBTVInstallDownloader: Sendable {
    public static func downloadPackage(from url: URL) async throws -> ADBTVDownloadedPackage {
        let (data, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            throw ADBTVInstallDownloadError.unacceptableStatusCode(httpResponse.statusCode)
        }

        let fileName: String?
        if url.lastPathComponent.isEmpty {
            fileName = nil
        } else {
            fileName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        }
        return ADBTVDownloadedPackage(contents: Array(data), fileName: fileName)
    }
}

public enum ADBTVInstallDownloadError: Error, Equatable, Sendable {
    case unacceptableStatusCode(Int)
}

public enum ADBTVInstallOperationError: Error, Equatable, Sendable {
    case missingDevice
    case missingPackage
    case missingPackageFile
    case unsupportedPlatform
}
