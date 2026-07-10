import ADBClientCore
import Foundation

public struct ADBTVAppModel: Equatable, Sendable {
    public var devices: [ADBTVDeviceSummary]
    public var selectedDeviceID: ADBTVDeviceSummary.ID?
    public var installDraft: ADBTVInstallDraft
    public var remoteStatus: ADBTVRemoteStatus
    public var discoveryStatus: ADBTVDiscoveryStatus
    public var discoveredServices: [ADBDiscoveredService]
    public var pairingDraft: ADBTVPairingDraft
    public var pairingStatus: ADBTVPairingStatus

    public init(
        devices: [ADBTVDeviceSummary] = [],
        selectedDeviceID: ADBTVDeviceSummary.ID? = nil,
        installDraft: ADBTVInstallDraft = ADBTVInstallDraft(),
        remoteStatus: ADBTVRemoteStatus = .idle,
        discoveryStatus: ADBTVDiscoveryStatus = .idle,
        discoveredServices: [ADBDiscoveredService] = [],
        pairingDraft: ADBTVPairingDraft = ADBTVPairingDraft(),
        pairingStatus: ADBTVPairingStatus = .idle
    ) {
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID ?? devices.first?.id
        self.installDraft = installDraft
        self.remoteStatus = remoteStatus
        self.discoveryStatus = discoveryStatus
        self.discoveredServices = discoveredServices.sortedForPresentation()
        self.pairingDraft = pairingDraft
        self.pairingStatus = pairingStatus
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

    @discardableResult
    public mutating func addDevice(_ device: ADBTVDeviceSummary) -> ADBTVDeviceSummary {
        if let index = devices.firstIndex(where: { $0.matchesEndpoint(of: device) }) {
            var updatedDevice = device
            updatedDevice.id = devices[index].id
            devices[index] = updatedDevice
            selectedDeviceID = updatedDevice.id
            return updatedDevice
        }

        devices.append(device)
        selectedDeviceID = device.id
        return device
    }

    public mutating func removeDevices(ids: Set<ADBTVDeviceSummary.ID>) {
        devices.removeAll { ids.contains($0.id) }

        if let selectedDeviceID, ids.contains(selectedDeviceID) {
            self.selectedDeviceID = devices.first?.id
        }
    }

    public mutating func selectPackage(fileName: String, byteCount: Int64?) {
        installDraft.selectedPackage = ADBTVInstallPackageDraft(fileName: fileName, byteCount: byteCount)
        installDraft.urlString = ""
        installDraft.status = .ready
    }

    public mutating func selectPackage(fileURL: URL, byteCount: Int64?) {
        installDraft.selectedPackage = ADBTVInstallPackageDraft(fileURL: fileURL, byteCount: byteCount)
        installDraft.urlString = ""
        installDraft.status = .ready
    }

    public mutating func setInstallURLString(_ value: String) {
        installDraft.urlString = value
        installDraft.selectedPackage = nil
        installDraft.status = installDraft.canBuildInstallPlan ? .ready : .idle
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

    public mutating func startDiscovery() {
        discoveryStatus = .browsing
        discoveredServices = []
    }

    public mutating func updateDiscoveredServices(_ services: [ADBDiscoveredService]) {
        discoveredServices = services.sortedForPresentation()
        if !discoveryStatus.isBrowsing {
            discoveryStatus = .browsing
        }
    }

    public mutating func stopDiscovery() {
        discoveryStatus = .idle
    }

    public mutating func failDiscovery(userMessage: String, diagnosticDetail: DiagnosticDetail) {
        discoveryStatus = .failed(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
    }

    public mutating func setPairingCodeString(_ value: String) {
        pairingDraft.codeString = value
    }

    public mutating func setPairingDisplayName(_ value: String) {
        pairingDraft.displayName = value
    }

    public mutating func setPairingHost(_ value: String) {
        pairingDraft.host = value
    }

    public mutating func setPairingPortString(_ value: String) {
        pairingDraft.pairingPortString = value
    }

    public mutating func setConnectionPortString(_ value: String) {
        pairingDraft.connectionPortString = value
    }

    public mutating func setPairingQRCodePayload(_ value: String) {
        pairingDraft.qrPayload = value
    }

    public mutating func startPairing(source: ADBTVPairingSource, target: String) {
        pairingStatus = .pairing(source: source, target: target)
    }

    public mutating func finishPairing(device: ADBTVDeviceSummary) {
        let savedDevice = addDevice(device)
        pairingDraft.codeString = ""
        pairingStatus = .paired(savedDevice)
    }

    public mutating func failPairing(userMessage: String, diagnosticDetail: DiagnosticDetail) {
        pairingStatus = .failed(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
    }

    public mutating func cancelPairing() {
        pairingDraft.codeString = ""
        pairingStatus = .idle
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

    fileprivate func matchesEndpoint(of other: ADBTVDeviceSummary) -> Bool {
        host.caseInsensitiveCompare(other.host) == .orderedSame && port == other.port
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
        if selectedPackage != nil {
            return (try? installPlan()) != nil
        }

        guard let urlFileName else {
            return false
        }

        return (try? ADBAPKInstallPlan.singleAPK(fileName: urlFileName)) != nil
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

    public var urlFileName: String? {
        guard let validatedURL else {
            return nil
        }

        let fileName = validatedURL.lastPathComponent.removingPercentEncoding ?? validatedURL.lastPathComponent
        return fileName.isEmpty ? nil : fileName
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

public enum ADBTVDiscoveryStatus: Equatable, Sendable {
    case idle
    case browsing
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    public var isBrowsing: Bool {
        if case .browsing = self {
            return true
        }

        return false
    }
}

public enum ADBTVPairingSource: Equatable, Sendable {
    case manualCode
    case qrCode
}

public enum ADBTVPairingStatus: Equatable, Sendable {
    case idle
    case pairing(source: ADBTVPairingSource, target: String)
    case paired(ADBTVDeviceSummary)
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    public var isPairing: Bool {
        if case .pairing = self {
            return true
        }

        return false
    }
}

public struct ADBTVPairingDraft: Equatable, Sendable {
    public var displayName: String
    public var host: String
    public var pairingPortString: String
    public var connectionPortString: String
    public var codeString: String
    public var qrPayload: String

    public init(
        displayName: String = "",
        host: String = "",
        pairingPortString: String = "",
        connectionPortString: String = "",
        codeString: String = "",
        qrPayload: String = ""
    ) {
        self.displayName = displayName
        self.host = host
        self.pairingPortString = pairingPortString
        self.connectionPortString = connectionPortString
        self.codeString = codeString
        self.qrPayload = qrPayload
    }

    public var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedDisplayName: String {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? normalizedHost : value
    }

    public var pairingPort: UInt16? {
        validatedPort(pairingPortString)
    }

    public var connectionPort: UInt16? {
        validatedPort(connectionPortString)
    }

    public var pairingCode: ADBPairingCode? {
        try? ADBPairingCode(codeString)
    }

    public var pairingQRCode: ADBPairingQRCode? {
        try? ADBPairingQRCode(payload: qrPayload)
    }

    public var canStartManualPairing: Bool {
        !normalizedHost.isEmpty
            && pairingPort != nil
            && connectionPort != nil
            && pairingCode != nil
    }

    public var canStartQRPairing: Bool {
        pairingQRCode != nil
    }

    private func validatedPort(_ value: String) -> UInt16? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(value), port > 0 else {
            return nil
        }

        return port
    }
}
