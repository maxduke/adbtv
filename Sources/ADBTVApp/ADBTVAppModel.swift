import ADBClientCore
import Foundation

public struct ADBTVAppModel: Equatable, Sendable {
    public var devices: [ADBTVDeviceSummary]
    public var selectedDeviceID: ADBTVDeviceSummary.ID?
    public var installDraft: ADBTVInstallDraft
    public var remoteStatus: ADBTVRemoteStatus
    public var remoteTextString: String
    public var discoveryStatus: ADBTVDiscoveryStatus
    public var discoveredServices: [ADBDiscoveredService]
    public var pairingDraft: ADBTVPairingDraft
    public var pairingStatus: ADBTVPairingStatus
    public var activeDeviceOperation: ADBTVActiveDeviceOperation?

    public init(
        devices: [ADBTVDeviceSummary] = [],
        selectedDeviceID: ADBTVDeviceSummary.ID? = nil,
        installDraft: ADBTVInstallDraft = ADBTVInstallDraft(),
        remoteStatus: ADBTVRemoteStatus = .idle,
        remoteTextString: String = "",
        discoveryStatus: ADBTVDiscoveryStatus = .idle,
        discoveredServices: [ADBDiscoveredService] = [],
        pairingDraft: ADBTVPairingDraft = ADBTVPairingDraft(),
        pairingStatus: ADBTVPairingStatus = .idle,
        activeDeviceOperation: ADBTVActiveDeviceOperation? = nil
    ) {
        self.devices = devices
        self.selectedDeviceID = selectedDeviceID ?? devices.first?.id
        self.installDraft = installDraft
        self.remoteStatus = remoteStatus
        self.remoteTextString = remoteTextString
        self.discoveryStatus = discoveryStatus
        self.discoveredServices = discoveredServices.sortedForPresentation()
        self.pairingDraft = pairingDraft
        self.pairingStatus = pairingStatus
        self.activeDeviceOperation = activeDeviceOperation
    }

    public var selectedDevice: ADBTVDeviceSummary? {
        guard let selectedDeviceID else {
            return nil
        }

        return devices.first { $0.id == selectedDeviceID }
    }

    public var canInstallSelectedPackage: Bool {
        selectedDevice != nil
            && installDraft.canBuildInstallPlan
            && activeDeviceOperation == nil
    }

    public var remoteText: ADBTVRemoteText? {
        try? ADBTVRemoteText(remoteTextString)
    }

    public var canSendRemoteText: Bool {
        selectedDevice != nil
            && remoteText != nil
            && activeDeviceOperation == nil
    }

    public var canStartDeviceOperation: Bool {
        selectedDevice != nil && activeDeviceOperation == nil
    }

    @discardableResult
    public mutating func selectDevice(id: ADBTVDeviceSummary.ID?) -> Bool {
        guard activeDeviceOperation == nil || activeDeviceOperation?.deviceID == id else {
            return false
        }
        selectedDeviceID = id
        return true
    }

    @discardableResult
    public mutating func addDevice(_ device: ADBTVDeviceSummary) -> ADBTVDeviceSummary {
        if let index = devices.firstIndex(where: { $0.matchesEndpoint(of: device) }) {
            var updatedDevice = device
            updatedDevice.id = devices[index].id
            devices[index] = updatedDevice
            if activeDeviceOperation == nil {
                selectedDeviceID = updatedDevice.id
            }
            return updatedDevice
        }

        devices.append(device)
        if activeDeviceOperation == nil {
            selectedDeviceID = device.id
        }
        return device
    }

    public mutating func removeDevices(ids: Set<ADBTVDeviceSummary.ID>) {
        let protectedDeviceID = activeDeviceOperation?.deviceID
        devices.removeAll { ids.contains($0.id) && $0.id != protectedDeviceID }

        if let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
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

    @discardableResult
    public mutating func startInstall(on deviceID: ADBTVDeviceSummary.ID) -> Bool {
        guard selectedDeviceID == deviceID,
              installDraft.canBuildInstallPlan,
              activeDeviceOperation == nil else {
            return false
        }

        activeDeviceOperation = .install(deviceID: deviceID)
        if installDraft.selectedPackage == nil, installDraft.validatedURL != nil {
            installDraft.status = .downloading(receivedByteCount: 0, totalByteCount: nil)
        } else {
            installDraft.status = .running(.validatePackage)
        }
        return true
    }

    @discardableResult
    public mutating func recordInstallEvent(
        _ event: ADBTVInstallEvent,
        on deviceID: ADBTVDeviceSummary.ID
    ) -> Bool {
        guard activeDeviceOperation == .install(deviceID: deviceID),
              installDraft.status.isRunning else {
            return false
        }

        switch event {
        case .download(let progress):
            installDraft.status = .downloading(
                receivedByteCount: progress.receivedByteCount,
                totalByteCount: progress.totalByteCount
            )
        case .installer(let event):
            installDraft.status = ADBTVInstallStatus(event: event)
        }
        return true
    }

    @discardableResult
    public mutating func finishInstall(
        result: ADBAPKInstallResult,
        on deviceID: ADBTVDeviceSummary.ID
    ) -> Bool {
        guard activeDeviceOperation == .install(deviceID: deviceID) else {
            return false
        }
        activeDeviceOperation = nil
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
        return true
    }

    public mutating func failInstall(userMessage: String, diagnosticDetail: DiagnosticDetail) {
        installDraft.status = .failed(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
    }

    @discardableResult
    public mutating func failInstall(
        userMessage: String,
        diagnosticDetail: DiagnosticDetail,
        on deviceID: ADBTVDeviceSummary.ID
    ) -> Bool {
        guard activeDeviceOperation == .install(deviceID: deviceID) else {
            return false
        }
        activeDeviceOperation = nil
        failInstall(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        return true
    }

    @discardableResult
    public mutating func cancelInstall(on deviceID: ADBTVDeviceSummary.ID) -> Bool {
        guard activeDeviceOperation == .install(deviceID: deviceID) else {
            return false
        }
        activeDeviceOperation = nil
        installDraft.status = .cancelled
        return true
    }

    public mutating func cancelActiveDeviceOperation() {
        guard let activeDeviceOperation else {
            return
        }
        self.activeDeviceOperation = nil

        switch activeDeviceOperation {
        case .install:
            installDraft.status = .cancelled
        case .remoteAction, .remoteText:
            remoteStatus = .idle
        }
    }

    @discardableResult
    public mutating func recordRemoteActionStarted(
        _ action: ADBTVRemoteAction,
        on deviceID: ADBTVDeviceSummary.ID
    ) -> Bool {
        guard selectedDeviceID == deviceID, activeDeviceOperation == nil else {
            return false
        }
        activeDeviceOperation = .remoteAction(deviceID: deviceID, action: action)
        remoteStatus = .sending(action)
        return true
    }

    @discardableResult
    public mutating func finishRemoteAction(
        _ action: ADBTVRemoteAction,
        on deviceID: ADBTVDeviceSummary.ID
    ) -> Bool {
        guard activeDeviceOperation == .remoteAction(deviceID: deviceID, action: action) else {
            return false
        }
        activeDeviceOperation = nil
        remoteStatus = .sent(action)
        return true
    }

    @discardableResult
    public mutating func failRemoteAction(
        _ action: ADBTVRemoteAction,
        userMessage: String,
        diagnosticDetail: DiagnosticDetail,
        on deviceID: ADBTVDeviceSummary.ID
    ) -> Bool {
        guard activeDeviceOperation == .remoteAction(deviceID: deviceID, action: action) else {
            return false
        }
        activeDeviceOperation = nil
        remoteStatus = .failed(action: action, userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        return true
    }

    public mutating func setRemoteTextString(_ value: String) {
        remoteTextString = value
    }

    @discardableResult
    public mutating func recordRemoteTextStarted(on deviceID: ADBTVDeviceSummary.ID) -> Bool {
        guard selectedDeviceID == deviceID, activeDeviceOperation == nil else {
            return false
        }
        activeDeviceOperation = .remoteText(deviceID: deviceID)
        remoteStatus = .sendingText
        return true
    }

    @discardableResult
    public mutating func finishRemoteText(on deviceID: ADBTVDeviceSummary.ID) -> Bool {
        guard activeDeviceOperation == .remoteText(deviceID: deviceID) else {
            return false
        }
        activeDeviceOperation = nil
        remoteStatus = .sentText
        remoteTextString = ""
        return true
    }

    @discardableResult
    public mutating func failRemoteText(
        userMessage: String,
        diagnosticDetail: DiagnosticDetail,
        on deviceID: ADBTVDeviceSummary.ID
    ) -> Bool {
        guard activeDeviceOperation == .remoteText(deviceID: deviceID) else {
            return false
        }
        activeDeviceOperation = nil
        remoteStatus = .failedText(
            userMessage: userMessage,
            diagnosticDetail: diagnosticDetail
        )
        return true
    }

    public mutating func startDiscovery() {
        discoveryStatus = .browsing
        discoveredServices = []
    }

    public mutating func waitForLocalNetworkAuthorization(
        userMessage: String,
        diagnosticDetail: DiagnosticDetail
    ) {
        discoveryStatus = .waitingForLocalNetworkAuthorization(
            userMessage: userMessage,
            diagnosticDetail: diagnosticDetail
        )
    }

    public mutating func markDiscoveryReady() {
        if case .waitingForLocalNetworkAuthorization = discoveryStatus {
            discoveryStatus = .browsing
        }
    }

    @discardableResult
    public mutating func updateDiscoveredServices(
        _ services: [ADBDiscoveredService]
    ) -> ADBTVDeviceSummary? {
        discoveredServices = services.sortedForPresentation()
        discoveryStatus = .browsing

        return beginPendingDiscoveredPairingVerificationIfPossible()
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

    public mutating func prepareManualPairing() {
        pairingDraft = ADBTVPairingDraft()
        pairingStatus = .idle
    }

    public mutating func prepareDiscoveredPairing(service: ADBDiscoveredService) {
        pairingDraft = ADBTVPairingDraft(discoveredService: service)
        pairingStatus = .idle
    }

    public mutating func prepareQRCodePairing(payload: String) {
        pairingDraft = ADBTVPairingDraft(qrPayload: payload)
        if let serviceName = pairingDraft.pairingQRCode?.serviceName {
            pairingStatus = .waitingForPairingService(serviceName: serviceName)
        } else {
            pairingStatus = .failed(
                userMessage: "This is not an Android pairing QR code.",
                diagnosticDetail: DiagnosticDetail(
                    summary: "The scanned payload is not a supported ADB pairing payload.",
                    context: ["operation": "parsePairingQRCode"]
                )
            )
        }
    }

    @discardableResult
    public mutating func selectQRCodePairingServiceIfAvailable() -> Bool {
        guard case .waitingForPairingService(let serviceName) = pairingStatus,
              let service = discoveredServices.first(where: {
                  $0.kind == .pairing && $0.serviceName == serviceName
              }) else {
            return false
        }

        pairingDraft.discoveredService = service
        return true
    }

    public mutating func startPairing(source: ADBTVPairingSource, target: String) {
        pairingStatus = .pairing(source: source, target: target)
    }

    public mutating func finishPairing(device: ADBTVDeviceSummary) {
        let savedDevice = addDevice(device)
        pairingDraft.codeString = ""
        pairingStatus = .paired(savedDevice)
    }

    public mutating func beginPairingConnectionVerification(device: ADBTVDeviceSummary) {
        pairingStatus = .verifyingConnection(device)
    }

    @discardableResult
    public mutating func finishPairingConnectionVerification(
        expectedDeviceID: UUID,
        verifiedDevice: ADBTVDeviceSummary
    ) -> Bool {
        guard case .verifyingConnection(let candidate) = pairingStatus,
              candidate.id == expectedDeviceID,
              verifiedDevice.id == expectedDeviceID else {
            return false
        }

        finishPairing(device: verifiedDevice)
        return true
    }

    @discardableResult
    public mutating func failPairingConnectionVerification(
        expectedDeviceID: UUID,
        userMessage: String,
        diagnosticDetail: DiagnosticDetail
    ) -> Bool {
        guard case .verifyingConnection(let candidate) = pairingStatus,
              candidate.id == expectedDeviceID else {
            return false
        }

        failPairing(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        return true
    }

    public mutating func failPairing(userMessage: String, diagnosticDetail: DiagnosticDetail) {
        pairingStatus = .failed(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
    }

    @discardableResult
    public mutating func failWaitingForPairingService(
        serviceName: String,
        userMessage: String,
        diagnosticDetail: DiagnosticDetail
    ) -> Bool {
        guard case .waitingForPairingService(let currentServiceName) = pairingStatus,
              currentServiceName == serviceName else {
            return false
        }
        failPairing(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        return true
    }

    @discardableResult
    public mutating func failWaitingForConnection(
        deviceGUID: String,
        userMessage: String,
        diagnosticDetail: DiagnosticDetail
    ) -> Bool {
        guard case .waitingForConnection(let currentGUID, _) = pairingStatus,
              currentGUID == deviceGUID else {
            return false
        }
        failPairing(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        return true
    }

    @discardableResult
    public mutating func waitForDiscoveredConnection(
        deviceGUID: String,
        displayName: String
    ) -> ADBTVDeviceSummary? {
        pairingStatus = .waitingForConnection(
            deviceGUID: deviceGUID,
            displayName: displayName
        )
        return beginPendingDiscoveredPairingVerificationIfPossible()
    }

    public mutating func cancelPairing() {
        pairingDraft.codeString = ""
        pairingDraft.qrPayload = ""
        pairingStatus = .idle
    }

    private mutating func beginPendingDiscoveredPairingVerificationIfPossible(
    ) -> ADBTVDeviceSummary? {
        guard case let .waitingForConnection(deviceGUID, displayName) = pairingStatus,
              let service = discoveredServices.first(where: {
                  $0.kind == .connect && $0.serviceName == deviceGUID
              }) else {
            return nil
        }

        let device = ADBTVDeviceSummary(
            displayName: displayName,
            bonjourService: service
        )
        beginPairingConnectionVerification(device: device)
        return device
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
                fileURL: URL(fileURLWithPath: "/tmp/3.8.4-1-complete-armeabi-v7a.apk"),
                byteCount: 78_334_696
            ),
            status: .ready
        )
    )
}

public struct ADBTVDeviceSummary: Codable, Identifiable, Equatable, Sendable {
    public typealias ID = UUID

    public var id: ID
    public var displayName: String
    public var model: String?
    public var connection: ADBTVDeviceConnection

    public init(
        id: ID = ID(),
        displayName: String,
        host: String,
        port: Int,
        model: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.model = model
        self.connection = .hostPort(host: host, port: port)
    }

    public init(
        id: ID = ID(),
        displayName: String,
        bonjourService: ADBDiscoveredService,
        model: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.model = model
        self.connection = .bonjour(bonjourService)
    }

    public var host: String {
        switch connection {
        case .hostPort(let host, _):
            return host
        case .bonjour(let service):
            return service.serviceName
        }
    }

    public var port: Int {
        switch connection {
        case .hostPort(_, let port):
            return port
        case .bonjour:
            return 0
        }
    }

    public var bonjourService: ADBDiscoveredService? {
        guard case .bonjour(let service) = connection else {
            return nil
        }

        return service
    }

    public var connectionDescription: String {
        switch connection {
        case let .hostPort(host, port):
            return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        case .bonjour(let service):
            return "\(service.serviceName) via Bonjour"
        }
    }

    fileprivate func matchesEndpoint(of other: ADBTVDeviceSummary) -> Bool {
        switch (connection, other.connection) {
        case let (.bonjour(lhs), .bonjour(rhs)):
            return lhs.serviceName == rhs.serviceName
                && lhs.serviceType == rhs.serviceType
                && lhs.domain == rhs.domain
        case let (.hostPort(lhsHost, lhsPort), .hostPort(rhsHost, rhsPort)):
            return lhsHost.caseInsensitiveCompare(rhsHost) == .orderedSame
                && lhsPort == rhsPort
        case (.bonjour, .hostPort), (.hostPort, .bonjour):
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case model
        case connection
        case host
        case port
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        model = try container.decodeIfPresent(String.self, forKey: .model)

        if let connection = try container.decodeIfPresent(
            ADBTVDeviceConnection.self,
            forKey: .connection
        ) {
            self.connection = connection
        } else {
            self.connection = .hostPort(
                host: try container.decode(String.self, forKey: .host),
                port: try container.decode(Int.self, forKey: .port)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(connection, forKey: .connection)
    }
}

public enum ADBTVDeviceConnection: Codable, Equatable, Sendable {
    case hostPort(host: String, port: Int)
    case bonjour(ADBDiscoveredService)
}

#if canImport(Network)
public extension ADBTVDeviceSummary {
    func networkTarget() throws -> ADBNetworkTarget {
        switch connection {
        case let .hostPort(host, portValue):
            guard let port = UInt16(exactly: portValue) else {
                throw ADBTVDeviceConnectionError.invalidPort(portValue)
            }
            return .hostPort(ADBNetworkEndpoint(host: host, port: port))
        case .bonjour(let service):
            guard service.kind == .connect else {
                throw ADBTVDeviceConnectionError.invalidBonjourServiceType(
                    service.serviceType
                )
            }
            return .bonjourService(service)
        }
    }
}

public enum ADBTVDeviceConnectionError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case invalidBonjourServiceType(String)
}
#endif

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

    public var usesInsecureHTTP: Bool {
        validatedURL?.scheme?.lowercased() == "http"
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
    case downloading(receivedByteCount: Int64, totalByteCount: Int64?)
    case transferring(sentByteCount: Int, totalByteCount: Int)
    case succeeded
    case cancelled
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    public init(event: ADBAPKInstallEvent) {
        switch event {
        case .phaseStarted(let phase):
            self = .running(phase)
        case .phaseFinished(let phase):
            self = .running(phase)
        case .transfer(let transferEvent):
            switch transferEvent {
            case .started(_, let totalByteCount):
                self = .transferring(sentByteCount: 0, totalByteCount: totalByteCount)
            case .progress(let sentByteCount, let totalByteCount),
                 .finishedSending(let sentByteCount, let totalByteCount):
                self = .transferring(
                    sentByteCount: sentByteCount,
                    totalByteCount: totalByteCount
                )
            case .completed:
                self = .running(.transferPackage)
            case .failed(let message):
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
        switch self {
        case .running, .downloading, .transferring:
            return true
        case .idle, .ready, .succeeded, .cancelled, .failed:
            return false
        }
    }
}

public enum ADBTVInstallDraftError: Error, Equatable, Sendable {
    case missingPackage
}

public enum ADBTVActiveDeviceOperation: Equatable, Sendable {
    case install(deviceID: ADBTVDeviceSummary.ID)
    case remoteAction(deviceID: ADBTVDeviceSummary.ID, action: ADBTVRemoteAction)
    case remoteText(deviceID: ADBTVDeviceSummary.ID)

    public var deviceID: ADBTVDeviceSummary.ID {
        switch self {
        case .install(let deviceID), .remoteAction(let deviceID, _), .remoteText(let deviceID):
            return deviceID
        }
    }
}

public enum ADBTVRemoteStatus: Equatable, Sendable {
    case idle
    case sending(ADBTVRemoteAction)
    case sendingText
    case sent(ADBTVRemoteAction)
    case sentText
    case failed(action: ADBTVRemoteAction, userMessage: String, diagnosticDetail: DiagnosticDetail)
    case failedText(userMessage: String, diagnosticDetail: DiagnosticDetail)

    public var isSending: Bool {
        switch self {
        case .sending, .sendingText:
            return true
        default:
            return false
        }
    }
}

public enum ADBTVDiscoveryStatus: Equatable, Sendable {
    case idle
    case browsing
    case waitingForLocalNetworkAuthorization(
        userMessage: String,
        diagnosticDetail: DiagnosticDetail
    )
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    public var isBrowsing: Bool {
        switch self {
        case .browsing, .waitingForLocalNetworkAuthorization:
            return true
        case .idle, .failed:
            return false
        }
    }
}

public enum ADBTVPairingSource: Equatable, Sendable {
    case manualCode
    case discoveredService
    case qrCode
}

public enum ADBTVPairingStatus: Equatable, Sendable {
    case idle
    case waitingForPairingService(serviceName: String)
    case pairing(source: ADBTVPairingSource, target: String)
    case waitingForConnection(deviceGUID: String, displayName: String)
    case verifyingConnection(ADBTVDeviceSummary)
    case paired(ADBTVDeviceSummary)
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    public var isPairing: Bool {
        switch self {
        case .waitingForPairingService, .pairing, .waitingForConnection, .verifyingConnection:
            return true
        default:
            return false
        }
    }
}

public struct ADBTVPairingDraft: Equatable, Sendable {
    public var displayName: String
    public var host: String
    public var pairingPortString: String
    public var connectionPortString: String
    public var codeString: String
    public var qrPayload: String
    public var discoveredService: ADBDiscoveredService?

    public init(
        displayName: String = "",
        host: String = "",
        pairingPortString: String = "",
        connectionPortString: String = "",
        codeString: String = "",
        qrPayload: String = "",
        discoveredService: ADBDiscoveredService? = nil
    ) {
        self.displayName = displayName
        self.host = host
        self.pairingPortString = pairingPortString
        self.connectionPortString = connectionPortString
        self.codeString = codeString
        self.qrPayload = qrPayload
        self.discoveredService = discoveredService
    }

    public var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedDisplayName: String {
        let value = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            return value
        }
        if !normalizedHost.isEmpty {
            return normalizedHost
        }

        return discoveredService?.displayName ?? "Android TV"
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

    public var canStartDiscoveredPairing: Bool {
        discoveredService?.kind == .pairing && pairingCode != nil
    }

    public var canStartPairing: Bool {
        canStartManualPairing || canStartDiscoveredPairing || canStartDiscoveredQRPairing
    }

    public var canStartQRPairing: Bool {
        pairingQRCode != nil
    }

    public var canStartDiscoveredQRPairing: Bool {
        guard let pairingQRCode, let discoveredService else {
            return false
        }

        return discoveredService.kind == .pairing
            && discoveredService.serviceName == pairingQRCode.serviceName
    }

    private func validatedPort(_ value: String) -> UInt16? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(value), port > 0 else {
            return nil
        }

        return port
    }
}
