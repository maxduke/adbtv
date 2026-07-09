import ADBClientCore
import Foundation

public struct ADBTVAppModel: Equatable, Sendable {
    public var devices: [ADBTVDeviceSummary]
    public var selectedDeviceID: ADBTVDeviceSummary.ID?
    public var installDraft: ADBTVInstallDraft
    public var remoteStatus: ADBTVRemoteStatus

    public init(
        devices: [ADBTVDeviceSummary] = [],
        selectedDeviceID: ADBTVDeviceSummary.ID? = nil,
        installDraft: ADBTVInstallDraft = ADBTVInstallDraft(),
        remoteStatus: ADBTVRemoteStatus = .idle
    ) {
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID ?? devices.first?.id
        self.installDraft = installDraft
        self.remoteStatus = remoteStatus
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

    public mutating func addDevice(_ device: ADBTVDeviceSummary) {
        devices.append(device)
        selectedDeviceID = device.id
    }

    public mutating func removeDevices(ids: Set<ADBTVDeviceSummary.ID>) {
        devices.removeAll { ids.contains($0.id) }

        if let selectedDeviceID, ids.contains(selectedDeviceID) {
            self.selectedDeviceID = devices.first?.id
        }
    }

    public mutating func selectPackage(fileName: String, byteCount: Int64?) {
        installDraft.selectedPackage = ADBTVInstallPackageDraft(fileName: fileName, byteCount: byteCount)
        installDraft.status = .ready
    }

    public mutating func selectPackage(fileURL: URL, byteCount: Int64?) {
        installDraft.selectedPackage = ADBTVInstallPackageDraft(fileURL: fileURL, byteCount: byteCount)
        installDraft.status = .ready
    }

    public mutating func setInstallURLString(_ value: String) {
        installDraft.urlString = value
    }

    public mutating func recordInstallEvent(_ event: ADBAPKInstallEvent) {
        installDraft.status = ADBTVInstallStatus(event: event)
    }

    public mutating func finishInstall(result: ADBAPKInstallResult) {
        switch result {
        case .success:
            installDraft.status = .succeeded
        case .failure(let message):
            installDraft.status = .failed(
                userMessage: "APK install failed.",
                diagnosticDetail: DiagnosticDetail(
                    summary: message,
                    context: ["phase": "installPackage"]
                )
            )
        }
    }

    public mutating func failInstall(userMessage: String, diagnosticDetail: DiagnosticDetail) {
        installDraft.status = .failed(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
    }

    public mutating func recordRemoteActionStarted(_ action: ADBTVRemoteAction) {
        remoteStatus = .sending(action)
    }

    public mutating func finishRemoteAction(_ action: ADBTVRemoteAction) {
        remoteStatus = .sent(action)
    }

    public mutating func failRemoteAction(
        _ action: ADBTVRemoteAction,
        userMessage: String,
        diagnosticDetail: DiagnosticDetail
    ) {
        remoteStatus = .failed(action: action, userMessage: userMessage, diagnosticDetail: diagnosticDetail)
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
            selectedPackage: ADBTVInstallPackageDraft(
                fileURL: URL(fileURLWithPath: "/tmp/example.apk"),
                byteCount: 42
            ),
            status: .ready
        )
    )
}

public struct ADBTVDeviceSummary: Codable, Identifiable, Equatable, Sendable {
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
        guard selectedPackage != nil else {
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
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        return url
    }
}

public struct ADBTVInstallPackageDraft: Equatable, Sendable {
    public var fileName: String
    public var fileURL: URL?
    public var byteCount: Int64?

    public init(fileName: String, fileURL: URL? = nil, byteCount: Int64? = nil) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.byteCount = byteCount
    }

    public init(fileURL: URL, byteCount: Int64? = nil) {
        self.init(fileName: fileURL.lastPathComponent, fileURL: fileURL, byteCount: byteCount)
    }
}

public enum ADBTVInstallStatus: Equatable, Sendable {
    case idle
    case ready
    case running(ADBAPKInstallPhase)
    case succeeded
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    public init(event: ADBAPKInstallEvent) {
        switch event {
        case .phaseStarted(let phase):
            self = .running(phase)
        case .phaseFinished(let phase):
            self = .running(phase)
        case .transfer(let transferEvent):
            self = .running(.transferPackage)
            if case .failed(let message) = transferEvent {
                self = .failed(
                    userMessage: "APK transfer failed.",
                    diagnosticDetail: DiagnosticDetail(
                        summary: message,
                        context: ["phase": "transferPackage"]
                    )
                )
            }
        case .installResult(let result):
            switch result {
            case .success:
                self = .running(.cleanup)
            case .failure(let message):
                self = .failed(
                    userMessage: "APK install failed.",
                    diagnosticDetail: DiagnosticDetail(
                        summary: message,
                        context: ["phase": "installPackage"]
                    )
                )
            }
        }
    }

    public var isRunning: Bool {
        if case .running = self {
            return true
        }

        return false
    }
}

public enum ADBTVInstallDraftError: Error, Equatable, Sendable {
    case missingPackage
}

public enum ADBTVRemoteStatus: Equatable, Sendable {
    case idle
    case sending(ADBTVRemoteAction)
    case sent(ADBTVRemoteAction)
    case failed(action: ADBTVRemoteAction, userMessage: String, diagnosticDetail: DiagnosticDetail)

    public var isSending: Bool {
        if case .sending = self {
            return true
        }

        return false
    }
}
