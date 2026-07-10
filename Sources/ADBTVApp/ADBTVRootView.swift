import ADBClientCore
import SwiftUI
import UniformTypeIdentifiers

public struct ADBTVRootView: View {
    private let deviceStore: ADBTVDeviceStore

    @State private var model: ADBTVAppModel
    @State private var isFileImporterPresented = false
    @State private var isAddDevicePresented = false
    @State private var isPairDevicePresented = false
    @State private var devicePersistenceError: DiagnosticDetail?
    @State private var installTask: Task<Void, Never>?
    @State private var remoteTask: Task<Void, Never>?
    @State private var pairingTask: Task<Void, Never>?
#if canImport(Network)
    @State private var discoveryBrowser: ADBBonjourServiceBrowser?
#endif

    public init(deviceStore: ADBTVDeviceStore = ADBTVDeviceStore()) {
        self.init(
            model: ADBTVAppModel(devices: deviceStore.loadDevices()),
            deviceStore: deviceStore
        )
    }

    public init(model: ADBTVAppModel, deviceStore: ADBTVDeviceStore = ADBTVDeviceStore()) {
        self.deviceStore = deviceStore
        self._model = State(initialValue: model)
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedDeviceID) {
                Section("Devices") {
                    if model.devices.isEmpty {
                        ContentUnavailableView("No Devices", systemImage: "tv")
                    } else {
                        ForEach(model.devices) { device in
                            DeviceRow(device: device)
                                .tag(device.id)
                        }
                        .onDelete(perform: deleteDevices)
                    }
                }

                Section("Discovery") {
                    DiscoveryContent(
                        status: model.discoveryStatus,
                        services: model.discoveredServices,
                        toggleDiscovery: toggleDiscovery,
                        pairService: prepareDiscoveredPairing
                    )
                }
            }
            .navigationTitle("ADB TV")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            model.prepareManualPairing()
                            isPairDevicePresented = true
                        } label: {
                            Label("Pair with Code", systemImage: "key")
                        }

                        Button {
                            isAddDevicePresented = true
                        } label: {
                            Label("Add Manually", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Label("Add Device", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let device = model.selectedDevice {
                DeviceDetailView(
                    device: device,
                    installDraft: model.installDraft,
                    installURLString: Binding(
                        get: { model.installDraft.urlString },
                        set: { model.setInstallURLString($0) }
                    ),
                    remoteStatus: model.remoteStatus,
                    canInstall: model.canInstallSelectedPackage,
                    chooseAPK: {
                        isFileImporterPresented = true
                    },
                    install: {
                        startInstall(for: device)
                    },
                    sendRemoteAction: { action in
                        sendRemoteAction(action, to: device)
                    }
                )
            } else {
                ContentUnavailableView("Select a Device", systemImage: "tv.and.hifispeaker.fill")
            }
        }
        .sheet(isPresented: $isAddDevicePresented) {
            AddDeviceView { device in
                addDevice(device)
            }
        }
        .sheet(isPresented: $isPairDevicePresented) {
            PairDeviceView(
                draft: $model.pairingDraft,
                status: model.pairingStatus,
                startPairing: startPairing,
                cancelPairing: cancelPairing
            )
        }
        .alert(
            "Could not save devices",
            isPresented: Binding(
                get: { devicePersistenceError != nil },
                set: { isPresented in
                    if !isPresented {
                        devicePersistenceError = nil
                    }
                }
            ),
            presenting: devicePersistenceError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { diagnosticDetail in
            Text(diagnosticDetail.summary)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.adbTVAPK],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                model.selectPackage(fileURL: url, byteCount: url.adbTVFileByteCount)
            case .failure(let error):
                model.failInstall(
                    userMessage: "Could not open the selected APK.",
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: ["source": "fileImporter"]
                    )
                )
            }
        }
        .onDisappear {
            installTask?.cancel()
            remoteTask?.cancel()
            cancelPairing()
            stopDiscovery()
        }
    }

    private func addDevice(_ device: ADBTVDeviceSummary) {
        model.addDevice(device)
        saveDevices()
    }

    private func deleteDevices(at offsets: IndexSet) {
        let ids = Set(offsets.map { model.devices[$0].id })
        model.removeDevices(ids: ids)
        saveDevices()
    }

    private func saveDevices() {
        do {
            try deviceStore.saveDevices(model.devices)
        } catch {
            devicePersistenceError = DiagnosticDetail(
                summary: String(describing: error),
                context: ["operation": "saveDevices"]
            )
        }
    }

    private func toggleDiscovery() {
        if model.discoveryStatus.isBrowsing {
            stopDiscovery()
        } else {
            startDiscovery()
        }
    }

    private func startDiscovery() {
        model.startDiscovery()
#if canImport(Network)
        let browser = ADBBonjourServiceBrowser()
        discoveryBrowser = browser
        browser.start(updateHandler: { services in
            if model.updateDiscoveredServices(services) {
                saveDevices()
            }
        }, failureHandler: { message in
            model.failDiscovery(
                userMessage: "Could not discover Android TV devices.",
                diagnosticDetail: DiagnosticDetail(
                    summary: message,
                    context: ["operation": "bonjourDiscovery"]
                )
            )
        })
#else
        model.failDiscovery(
            userMessage: "Device discovery is not available on this platform.",
            diagnosticDetail: DiagnosticDetail(
                summary: "Network.framework is unavailable.",
                context: ["operation": "bonjourDiscovery"]
            )
        )
#endif
    }

    private func prepareDiscoveredPairing(_ service: ADBDiscoveredService) {
        guard service.kind == .pairing else {
            return
        }

        model.prepareDiscoveredPairing(service: service)
        isPairDevicePresented = true
    }

    private func stopDiscovery() {
#if canImport(Network)
        discoveryBrowser?.cancel()
        discoveryBrowser = nil
#endif
        model.stopDiscovery()
    }

    private func startPairing() {
        let draft = model.pairingDraft
        guard draft.canStartPairing else {
            return
        }

        let source: ADBTVPairingSource
        let target: String
        if let service = draft.discoveredService {
            source = .discoveredService
            target = service.displayName
        } else if let pairingPort = draft.pairingPort {
            source = .manualCode
            target = Self.endpointDescription(host: draft.normalizedHost, port: pairingPort)
        } else {
            return
        }
        model.startPairing(source: source, target: target)

        pairingTask?.cancel()
        pairingTask = Task {
            let completion: PairingCompletion
            do {
                if draft.discoveredService != nil {
                    completion = .discovered(
                        deviceGUID: try await Self.pairDiscoveredDevice(using: draft),
                        displayName: draft.normalizedDisplayName
                    )
                } else {
                    completion = .success(try await Self.pairDevice(using: draft))
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                completion = .failure(
                    userMessage: "Could not pair with this Android TV.",
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: [
                            "operation": "pairDevice",
                            "target": target
                        ]
                    )
                )
            }

            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                completePairing(completion)
            }
        }
    }

    private static func pairDevice(using draft: ADBTVPairingDraft) async throws -> ADBTVDeviceSummary {
#if canImport(Network)
        try await ADBTVPairingOperation().pairManualCode(from: draft)
#else
        throw ADBTVPairingViewError.unsupportedPlatform
#endif
    }

    private static func pairDiscoveredDevice(using draft: ADBTVPairingDraft) async throws -> String {
#if canImport(Network)
        try await ADBTVPairingOperation().pairDiscoveredService(from: draft)
#else
        throw ADBTVPairingViewError.unsupportedPlatform
#endif
    }

    @MainActor
    private func completePairing(_ completion: PairingCompletion) {
        pairingTask = nil
        switch completion {
        case .success(let device):
            model.finishPairing(device: device)
            saveDevices()
        case let .discovered(deviceGUID, displayName):
            if model.waitForDiscoveredConnection(
                deviceGUID: deviceGUID,
                displayName: displayName
            ) {
                saveDevices()
            }
        case .failure(let userMessage, let diagnosticDetail):
            model.failPairing(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        }
    }

    private func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        model.cancelPairing()
    }

    private static func endpointDescription(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private func startInstall(for device: ADBTVDeviceSummary) {
        let installModel = model
        model.recordInstallEvent(.phaseStarted(.validatePackage))

        installTask?.cancel()
        installTask = Task {
            let completion: InstallCompletion
            do {
                completion = .success(try await Self.installPackage(for: device, using: installModel))
            } catch is CancellationError {
                return
            } catch {
                completion = .failure(
                    userMessage: "Could not install APK.",
                    diagnosticDetail: Self.installDiagnosticDetail(error, device: device)
                )
            }

            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                completeInstall(completion)
            }
        }
    }

    private static func installPackage(
        for device: ADBTVDeviceSummary,
        using installModel: ADBTVAppModel
    ) async throws -> ADBAPKInstallReport {
#if canImport(Network)
        guard case let .hostPort(host, portValue) = device.connection else {
            throw ADBTVInstallOperationError.secureReconnectNotImplemented
        }
        guard let port = UInt16(exactly: portValue) else {
            throw ADBTVInstallOperationError.invalidDevicePort(portValue)
        }

        let endpoint = ADBNetworkEndpoint(host: host, port: port)
#if canImport(Security)
        var connection = try ADBDeviceConnection(authenticatedEndpoint: endpoint)
#else
        var connection = ADBDeviceConnection(endpoint: endpoint)
#endif
        return try await ADBTVInstallOperation().installSelectedPackage(from: installModel, using: &connection)
#else
        throw ADBTVInstallOperationError.unsupportedPlatform
#endif
    }

    @MainActor
    private func completeInstall(_ completion: InstallCompletion) {
        switch completion {
        case .success(let report):
            for event in report.events {
                model.recordInstallEvent(event)
            }
            model.finishInstall(result: report.result)
        case .failure(let userMessage, let diagnosticDetail):
            model.failInstall(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        }
    }

    private static func installDiagnosticDetail(_ error: Error, device: ADBTVDeviceSummary) -> DiagnosticDetail {
        DiagnosticDetail(
            summary: String(describing: error),
            context: [
                "device": device.connectionDescription,
                "operation": "installAPK"
            ]
        )
    }

    private func sendRemoteAction(_ action: ADBTVRemoteAction, to device: ADBTVDeviceSummary) {
        let remoteModel = model
        model.recordRemoteActionStarted(action)

        remoteTask?.cancel()
        remoteTask = Task {
            let completion: RemoteCompletion
            do {
                _ = try await Self.sendRemoteAction(action, to: device, using: remoteModel)
                completion = .success(action)
            } catch is CancellationError {
                return
            } catch {
                completion = .failure(
                    action: action,
                    userMessage: "Could not send remote action.",
                    diagnosticDetail: Self.remoteDiagnosticDetail(error, action: action, device: device)
                )
            }

            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                completeRemoteAction(completion)
            }
        }
    }

    private static func sendRemoteAction(
        _ action: ADBTVRemoteAction,
        to device: ADBTVDeviceSummary,
        using remoteModel: ADBTVAppModel
    ) async throws -> ADBShellOutput {
#if canImport(Network)
        guard case let .hostPort(host, portValue) = device.connection else {
            throw ADBTVRemoteOperationError.secureReconnectNotImplemented
        }
        guard let port = UInt16(exactly: portValue) else {
            throw ADBTVRemoteOperationError.invalidDevicePort(portValue)
        }

        let endpoint = ADBNetworkEndpoint(host: host, port: port)
#if canImport(Security)
        var connection = try ADBDeviceConnection(authenticatedEndpoint: endpoint)
#else
        var connection = ADBDeviceConnection(endpoint: endpoint)
#endif
        return try await ADBTVRemoteOperation().sendAction(action, from: remoteModel, using: &connection)
#else
        throw ADBTVRemoteOperationError.unsupportedPlatform
#endif
    }

    @MainActor
    private func completeRemoteAction(_ completion: RemoteCompletion) {
        switch completion {
        case .success(let action):
            model.finishRemoteAction(action)
        case .failure(let action, let userMessage, let diagnosticDetail):
            model.failRemoteAction(action, userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        }
    }

    private static func remoteDiagnosticDetail(
        _ error: Error,
        action: ADBTVRemoteAction,
        device: ADBTVDeviceSummary
    ) -> DiagnosticDetail {
        DiagnosticDetail(
            summary: String(describing: error),
            context: [
                "action": action.displayTitle,
                "device": device.connectionDescription,
                "operation": "sendRemoteAction"
            ]
        )
    }
}

private enum PairingCompletion: Sendable {
    case success(ADBTVDeviceSummary)
    case discovered(deviceGUID: String, displayName: String)
    case failure(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

private enum ADBTVPairingViewError: Error {
    case unsupportedPlatform
}

private enum InstallCompletion: Sendable {
    case success(ADBAPKInstallReport)
    case failure(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

private enum RemoteCompletion: Sendable {
    case success(ADBTVRemoteAction)
    case failure(action: ADBTVRemoteAction, userMessage: String, diagnosticDetail: DiagnosticDetail)
}

private struct PairDeviceView: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var draft: ADBTVPairingDraft
    var status: ADBTVPairingStatus
    var startPairing: () -> Void
    var cancelPairing: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Name", text: $draft.displayName)
                    if let service = draft.discoveredService {
                        LabeledContent("Service", value: service.displayName)
                    } else {
                        TextField("Host or IP Address", text: $draft.host)
                            .autocorrectionDisabled()
                        TextField("Connection Port", text: $draft.connectionPortString)
                    }
                }

                Section("Pairing") {
                    if draft.discoveredService == nil {
                        TextField("Pairing Port", text: $draft.pairingPortString)
                    }
                    TextField("6-Digit Code", text: $draft.codeString)
                }

                PairingStatusView(status: status)
            }
            .disabled(status.isPairing)
            .navigationTitle("Pair Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasPaired ? "Done" : "Cancel") {
                        cancelPairing()
                        dismiss()
                    }
                }

                if !hasPaired {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Pair") {
                            startPairing()
                        }
                        .disabled(!draft.canStartPairing || status.isPairing)
                    }
                }
            }
        }
        .interactiveDismissDisabled(status.isPairing)
        .onDisappear {
            cancelPairing()
        }
    }

    private var hasPaired: Bool {
        if case .paired = status {
            return true
        }

        return false
    }
}

private struct PairingStatusView: View {
    var status: ADBTVPairingStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .pairing(_, let target):
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Pairing with \(target)")
                        .foregroundStyle(.secondary)
                }
            }
        case .waitingForConnection(let deviceGUID, _):
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding the connection service")
                        .foregroundStyle(.secondary)
                }
                Text(deviceGUID)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .paired(let device):
            Section {
                Label("Paired with \(device.displayName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved as \(device.connectionDescription)")
                    .foregroundStyle(.secondary)
            }
        case .failed(let userMessage, let diagnosticDetail):
            Section {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                DisclosureGroup("Technical Details") {
                    Text(diagnosticDetail.summary)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)

                    ForEach(diagnosticDetail.context.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(diagnosticDetail.context[key] ?? "")")
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var host = ""
    @State private var port = "5555"

    var addDevice: (ADBTVDeviceSummary) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $displayName)
                TextField("Host", text: $host)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
            }
            .navigationTitle("Add Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        submit()
                    }
                    .disabled(validatedDevice == nil)
                }
            }
        }
    }

    private var validatedDevice: ADBTVDeviceSummary? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              let portValue = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              UInt16(exactly: portValue) != nil else {
            return nil
        }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ADBTVDeviceSummary(
            displayName: trimmedDisplayName.isEmpty ? trimmedHost : trimmedDisplayName,
            host: trimmedHost,
            port: portValue
        )
    }

    private func submit() {
        guard let device = validatedDevice else {
            return
        }

        addDevice(device)
        dismiss()
    }
}

private struct DiscoveryContent: View {
    var status: ADBTVDiscoveryStatus
    var services: [ADBDiscoveredService]
    var toggleDiscovery: () -> Void
    var pairService: (ADBDiscoveredService) -> Void

    var body: some View {
        Group {
            Button {
                toggleDiscovery()
            } label: {
                Label(
                    status.isBrowsing ? "Stop Discovery" : "Discover Devices",
                    systemImage: status.isBrowsing ? "stop.circle" : "dot.radiowaves.left.and.right"
                )
            }

            DiscoveryStatusView(status: status, serviceCount: services.count)

            ForEach(services) { service in
                DiscoveredServiceRow(service: service) {
                    pairService(service)
                }
            }
        }
    }
}

private struct DiscoveryStatusView: View {
    var status: ADBTVDiscoveryStatus
    var serviceCount: Int

    var body: some View {
        switch status {
        case .idle:
            if serviceCount == 0 {
                EmptyView()
            } else {
                Label("\(serviceCount) service\(serviceCount == 1 ? "" : "s") found", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .browsing:
            HStack(spacing: 8) {
                ProgressView()
                Text(serviceCount == 0 ? "Searching local network" : "\(serviceCount) service\(serviceCount == 1 ? "" : "s") found")
                    .foregroundStyle(.secondary)
            }
        case .failed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 6) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(diagnosticDetail.summary)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

private struct DiscoveredServiceRow: View {
    var service: ADBDiscoveredService
    var pair: () -> Void

    var body: some View {
        if service.kind == .pairing {
            Button {
                pair()
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(service.displayName)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if service.kind == .pairing {
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pair")
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let kind = service.kind?.displayName ?? service.serviceType
        if let interfaceName = service.interfaceName, !interfaceName.isEmpty {
            return "\(kind) on \(interfaceName)"
        }

        return kind
    }
}

private struct DeviceRow: View {
    var device: ADBTVDeviceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(device.displayName)
                .font(.headline)
            Text(device.connectionDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct DeviceDetailView: View {
    var device: ADBTVDeviceSummary
    var installDraft: ADBTVInstallDraft
    var installURLString: Binding<String>
    var remoteStatus: ADBTVRemoteStatus
    var canInstall: Bool
    var chooseAPK: () -> Void
    var install: () -> Void
    var sendRemoteAction: (ADBTVRemoteAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DeviceHeader(device: device)
                APKInstallPanel(
                    installDraft: installDraft,
                    installURLString: installURLString,
                    canInstall: canInstall,
                    chooseAPK: chooseAPK,
                    install: install
                )
                RemoteActionsPanel(
                    status: remoteStatus,
                    send: sendRemoteAction
                )
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
        }
        .navigationTitle(device.displayName)
    }
}

private struct DeviceHeader: View {
    var device: ADBTVDeviceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(device.displayName)
                .font(.largeTitle.bold())
            if let model = device.model {
                Text(model)
                    .foregroundStyle(.secondary)
            }
            Text(device.connectionDescription)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct APKInstallPanel: View {
    var installDraft: ADBTVInstallDraft
    var installURLString: Binding<String>
    var canInstall: Bool
    var chooseAPK: () -> Void
    var install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("APK Install")
                .font(.title2.bold())

            HStack(spacing: 12) {
                Button {
                    chooseAPK()
                } label: {
                    Label("Choose APK", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    install()
                } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInstall || installDraft.status.isRunning)
            }

            TextField("https://example.com/app.apk", text: installURLString)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            if !installURLString.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !installDraft.canBuildInstallPlan {
                Label("Enter a direct HTTP or HTTPS APK URL", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            if let package = installDraft.selectedPackage {
                LabeledContent("Package", value: package.fileName)
                if let byteCount = package.byteCount {
                    LabeledContent("Size", value: "\(byteCount) bytes")
                }
                if let fileURL = package.fileURL {
                    LabeledContent("Source", value: fileURL.lastPathComponent)
                }
            } else if let url = installDraft.validatedURL {
                LabeledContent("Source", value: url.absoluteString)
            }

            InstallStatusView(status: installDraft.status)
        }
    }
}

private struct InstallStatusView: View {
    var status: ADBTVInstallStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .ready:
            Label("Ready to install", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .running(let phase):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                Label(statusTitle(for: phase), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 8) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(diagnosticDetail.summary)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func statusTitle(for phase: ADBAPKInstallPhase) -> String {
        switch phase {
        case .validatePackage:
            return "Validating package"
        case .prepareRemoteDirectory:
            return "Preparing device"
        case .transferPackage:
            return "Transferring APK"
        case .installPackage:
            return "Installing"
        case .cleanup:
            return "Cleaning up"
        }
    }
}

private struct RemoteActionsPanel: View {
    var status: ADBTVRemoteStatus
    var send: (ADBTVRemoteAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote")
                .font(.title2.bold())

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Spacer()
                    Button {
                        send(.up)
                    } label: {
                        Label("Up", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    Spacer()
                }
                GridRow {
                    Button {
                        send(.left)
                    } label: {
                        Label("Left", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    Button {
                        send(.select)
                    } label: {
                        Text("OK")
                            .frame(minWidth: 44)
                    }
                    Button {
                        send(.right)
                    } label: {
                        Label("Right", systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                    }
                }
                GridRow {
                    Spacer()
                    Button {
                        send(.down)
                    } label: {
                        Label("Down", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .disabled(status.isSending)

            HStack(spacing: 8) {
                Button {
                    send(.back)
                } label: {
                    Label("Back", systemImage: "arrow.uturn.backward")
                }
                Button {
                    send(.home)
                } label: {
                    Label("Home", systemImage: "house")
                }
                Button {
                    send(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .buttonStyle(.bordered)
            .disabled(status.isSending)

            RemoteStatusView(status: status)
        }
    }
}

private struct RemoteStatusView: View {
    var status: ADBTVRemoteStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .sending(let action):
            Label("Sending \(action.displayTitle)", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .sent(let action):
            Label("Sent \(action.displayTitle)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(_, let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 8) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(diagnosticDetail.summary)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

private extension ADBTVRemoteAction {
    var displayTitle: String {
        switch self {
        case .home:
            return "Home"
        case .back:
            return "Back"
        case .up:
            return "Up"
        case .down:
            return "Down"
        case .left:
            return "Left"
        case .right:
            return "Right"
        case .select:
            return "OK"
        case .settings:
            return "Settings"
        case .menu:
            return "Menu"
        case .volumeUp:
            return "Volume Up"
        case .volumeDown:
            return "Volume Down"
        case .power:
            return "Power"
        }
    }
}

private extension UTType {
    static var adbTVAPK: UTType {
        UTType(filenameExtension: "apk") ?? .data
    }
}

private extension URL {
    var adbTVFileByteCount: Int64? {
        let didStartAccessing = startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                stopAccessingSecurityScopedResource()
            }
        }

        guard let values = try? resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return nil
        }

        return Int64(fileSize)
    }
}
