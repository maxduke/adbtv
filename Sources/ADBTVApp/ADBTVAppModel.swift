import ADBClientCore
import Foundation

public struct ADBTVAppModel: Equatable, Sendable {
    public var devices: [ADBTVDeviceSummary]
    public var selectedDeviceID: ADBTVDeviceSummary.ID?
    public var installDraft: ADBTVInstallDraft

    public init(
        devices: [ADBTVDeviceSummary] = [],
        selectedDeviceID: ADBTVDeviceSummary.ID? = nil,
        installDraft: ADBTVInstallDraft = ADBTVInstallDraft()
    ) {
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID ?? devices.first?.id
        self.installDraft = installDraft
    }

    public var selectedDevice: ADBTVDeviceSummary? {
        guard let selectedDeviceID else {
            return nil
        }

        return devices.first { $0.id == selectedDeviceID }
    }

    public var canInstallSelectedPackage: Bool {
        selectedDevice != nil && installDraft.canBuildInstallPlan
    }

    public mutating func selectDevice(id: ADBTVDeviceSummary.ID?) {
        selectedDeviceID = id
    }

    public mutating func selectPackage(fileName: String, byteCount: Int64?) {
        installDraft.selectedPackage = ADBTVInstallPackageDraft(fileName: fileName, byteCount: byteCount)
        installDraft.status = .ready
    }

    public mutating func setInstallURLString(_ value: String) {
        installDraft.urlString = value
    }
}

public extension ADBTVAppModel {
    static let preview = ADBTVAppModel(
        devices: [
            ADBTVDeviceSummary(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                displayName: "Living Room TV",
                host: "192.168.1.50",
                port: 5555,
                model: "Android TV"
            )
        ],
        installDraft: ADBTVInstallDraft(
            selectedPackage: ADBTVInstallPackageDraft(fileName: "example.apk", byteCount: 42),
            status: .ready
        )
    )
}

public struct ADBTVDeviceSummary: Identifiable, Equatable, Sendable {
    public typealias ID = UUID

    public var id: ID
    public var displayName: String
    public var host: String
    public var port: Int
    public var model: String?

    public init(id: ID = ID(), displayName: String, host: String, port: Int, model: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.model = model
    }
}

public struct ADBTVInstallDraft: Equatable, Sendable {
    public var selectedPackage: ADBTVInstallPackageDraft?
    public var urlString: String
    public var status: ADBTVInstallStatus

    public init(
        selectedPackage: ADBTVInstallPackageDraft? = nil,
        urlString: String = "",
        status: ADBTVInstallStatus = .idle
    ) {
        self.selectedPackage = selectedPackage
        self.urlString = urlString
        self.status = status
    }

    public var canBuildInstallPlan: Bool {
        guard let selectedPackage else {
            return false
        }

        return (try? installPlan()) != nil
    }

    public func installPlan() throws -> ADBAPKInstallPlan {
        guard let selectedPackage else {
            throw ADBTVInstallDraftError.missingPackage
        }

        return try ADBAPKInstallPlan.singleAPK(
            fileName: selectedPackage.fileName,
            byteCount: selectedPackage.byteCount
        )
    }

    public var validatedURL: URL? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let url = components.url,
              components.host != nil else {
            return nil
        }

        return url
    }
}

public struct ADBTVInstallPackageDraft: Equatable, Sendable {
    public var fileName: String
    public var byteCount: Int64?

    public init(fileName: String, byteCount: Int64? = nil) {
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

public enum ADBTVInstallStatus: Equatable, Sendable {
    case idle
    case ready
    case running(ADBAPKInstallPhase)
    case succeeded
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

public enum ADBTVInstallDraftError: Error, Equatable, Sendable {
    case missingPackage
}
