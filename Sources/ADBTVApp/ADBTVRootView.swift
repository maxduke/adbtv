import ADBClientCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

public struct ADBTVRootView: View {
    @Environment(\.scenePhase) private var scenePhase
#if os(iOS)
    @Environment(\.openURL) private var openURL
#endif

    private let deviceStore: ADBTVDeviceStore
    private let bonjourCapability: ADBTVBonjourCapability

    @State private var model: ADBTVAppModel
    @State private var isFileImporterPresented = false
    @State private var isAddDevicePresented = false
    @State private var isPairDevicePresented = false
    @State private var isAboutPresented: Bool
    @State private var repairingDevice: ADBTVDeviceSummary?
    @State private var devicePersistenceError: DiagnosticDetail?
    @State private var installTask: Task<Void, Never>?
    @State private var remoteTask: Task<Void, Never>?
    @State private var pairingTask: Task<Void, Never>?
    @State private var deviceConnectionTask: Task<Void, Never>?
    @State private var deviceConnectionState = ADBTVSavedDeviceConnectionState.idle
    @State private var automaticDiscoveryPolicy = ADBTVAutomaticDiscoveryPolicy()
#if os(iOS) && canImport(AVFoundation)
    @State private var isQRCodeScannerPresented = false
    @State private var qrScannerError: DiagnosticDetail?
#endif
#if canImport(Network)
    @State private var discoveryBrowser: ADBBonjourServiceBrowser?
#endif

    public init(
        deviceStore: ADBTVDeviceStore = ADBTVDeviceStore(),
        automaticallyStartsDiscovery: Bool? = nil,
        bonjourDiscoveryAvailable: Bool? = nil,
        initiallyPresentsAbout: Bool = false
    ) {
        let loadResult = deviceStore.loadDevices()
        var initialModel = ADBTVAppModel(devices: loadResult.devices)
        _ = initialModel.selectDevice(id: nil)
        self.deviceStore = deviceStore
        self.bonjourCapability = bonjourDiscoveryAvailable.map {
            ADBTVBonjourCapability(
                isAvailable: $0,
                automaticallyStartsDiscovery: automaticallyStartsDiscovery
            )
        } ?? .current(automaticallyStartsDiscovery: automaticallyStartsDiscovery)
        self._model = State(initialValue: initialModel)
        self._isAboutPresented = State(initialValue: initiallyPresentsAbout)
        self._repairingDevice = State(initialValue: nil)
        self._devicePersistenceError = State(
            initialValue: Self.deviceLoadDiagnosticDetail(for: loadResult)
        )
    }

    public init(
        model: ADBTVAppModel,
        deviceStore: ADBTVDeviceStore = ADBTVDeviceStore(),
        automaticallyStartsDiscovery: Bool? = nil,
        bonjourDiscoveryAvailable: Bool? = nil,
        initiallyPresentsAbout: Bool = false,
        initiallyPresentsConnectionRepair: Bool = false
    ) {
        self.deviceStore = deviceStore
        self.bonjourCapability = bonjourDiscoveryAvailable.map {
            ADBTVBonjourCapability(
                isAvailable: $0,
                automaticallyStartsDiscovery: automaticallyStartsDiscovery
            )
        } ?? .current(automaticallyStartsDiscovery: automaticallyStartsDiscovery)
        self._model = State(initialValue: model)
        self._isAboutPresented = State(initialValue: initiallyPresentsAbout)
        self._repairingDevice = State(
            initialValue: initiallyPresentsConnectionRepair ? model.devices.first : nil
        )
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { deviceConnectionState.device?.id ?? model.selectedDeviceID },
                set: { selectSavedDevice(id: $0) }
            )) {
                Section("Devices") {
                    if model.devices.isEmpty {
                        ContentUnavailableView("No Devices", systemImage: "tv")
                    } else {
                        ForEach(model.devices) { device in
                            DeviceRow(device: device)
                                .tag(device.id)
                                .deleteDisabled(
                                    model.activeDeviceOperation != nil
                                        || deviceConnectionState.isConnecting
                                )
                        }
                        .onDelete(perform: deleteDevices)
                    }
                }

                if bonjourCapability.isAvailable {
                    Section("Discovery") {
                        DiscoveryContent(
                            status: model.discoveryStatus,
                            services: model.discoveredServices,
                            canPair: model.activeDeviceOperation == nil
                                && !deviceConnectionState.isConnecting,
                            toggleDiscovery: toggleDiscovery,
                            pairService: prepareDiscoveredPairing
                        )
                    }
                }
            }
            .navigationTitle("ADB TV")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isAboutPresented = true
                    } label: {
                        Label("About", systemImage: "info.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help("About")

                    Menu {
                        Button {
                            model.prepareManualPairing()
                            isPairDevicePresented = true
                        } label: {
                            Label("Pair with Code", systemImage: "key")
                        }

#if os(iOS) && canImport(AVFoundation)
                        if bonjourCapability.isAvailable {
                            Button {
                                presentQRCodeScanner()
                            } label: {
                                Label("Scan Pairing QR Code", systemImage: "qrcode.viewfinder")
                            }
                        }
#endif

                        Button {
                            isAddDevicePresented = true
                        } label: {
                            Label("Add Manually", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Label("Add Device", systemImage: "plus")
                    }
                    .disabled(
                        model.activeDeviceOperation != nil
                            || deviceConnectionState.isConnecting
                    )
                }
            }
        } detail: {
            if let connectionDevice = deviceConnectionState.device {
                SavedDeviceConnectionView(
                    device: connectionDevice,
                    state: deviceConnectionState,
                    retry: { selectSavedDevice(id: connectionDevice.id) },
                    repair: { repairingDevice = connectionDevice }
                )
            } else if let device = model.selectedDevice {
                DeviceDetailView(
                    device: device,
                    installDraft: model.installDraft,
                    installURLString: Binding(
                        get: { model.installDraft.urlString },
                        set: { model.setInstallURLString($0) }
                    ),
                    remoteStatus: model.remoteStatus,
                    remoteTextString: Binding(
                        get: { model.remoteTextString },
                        set: { model.setRemoteTextString($0) }
                    ),
                    canInstall: model.canInstallSelectedPackage,
                    canSendRemoteText: model.canSendRemoteText,
                    deviceOperationInProgress: model.activeDeviceOperation != nil,
                    chooseAPK: {
                        isFileImporterPresented = true
                    },
                    install: {
                        startInstall(for: device)
                    },
                    cancelInstall: cancelInstall,
                    sendRemoteAction: { action in
                        sendRemoteAction(action, to: device)
                    },
                    sendRemoteText: {
                        sendRemoteText(to: device)
                    },
                    cancelRemoteOperation: cancelRemoteOperation,
                    installUnicodeInputHelper: {
                        installUnicodeInputHelper(on: device)
                    }
                )
            } else {
                ContentUnavailableView("Select a Device", systemImage: "tv.and.hifispeaker.fill")
            }
        }
        .sheet(isPresented: $isAddDevicePresented) {
            AddDeviceView(
                verifyDevice: Self.verifyManualDevice,
                addDevice: addDevice
            )
        }
        .sheet(item: $repairingDevice) { device in
            RepairDeviceConnectionView(
                device: device,
                verifyDevice: Self.verifySavedDevice,
                saveDevice: { verifiedDevice in
                    try replaceDeviceConnection(
                        verifiedDevice,
                        replacing: device.id
                    )
                }
            )
        }
        .sheet(isPresented: $isPairDevicePresented) {
            PairDeviceView(
                draft: $model.pairingDraft,
                status: model.pairingStatus,
                startPairing: startPairing,
                cancelPairing: cancelPairing
            )
        }
        .sheet(isPresented: $isAboutPresented) {
            ADBTVAboutView()
        }
#if os(iOS) && canImport(AVFoundation)
        .sheet(isPresented: $isQRCodeScannerPresented) {
            NavigationStack {
                ADBQRCodeScannerView(
                    onPayload: handleQRCodePayload,
                    onFailure: handleQRCodeScannerFailure
                )
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan Pairing QR")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            isQRCodeScannerPresented = false
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
        .alert(
            "Camera unavailable",
            isPresented: Binding(
                get: { qrScannerError != nil },
                set: { isPresented in
                    if !isPresented {
                        qrScannerError = nil
                    }
                }
            ),
            presenting: qrScannerError
        ) { detail in
            if detail.context["reason"] == "permissionDenied",
               let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") {
                    openURL(settingsURL)
                }
            }
            Button("Copy Technical Details") {
                UIPasteboard.general.string = detail.formattedDescription
            }
            Button("OK", role: .cancel) {}
        } message: { detail in
            Text(detail.formattedDescription)
        }
#endif
        .alert(
            "Device Library issue",
            isPresented: Binding(
                get: { devicePersistenceError != nil },
                set: { isPresented in
                    if !isPresented {
                        devicePersistenceError = nil
                    }
                }
            ),
            presenting: devicePersistenceError
        ) { diagnosticDetail in
#if os(iOS)
            Button("Copy Technical Details") {
                UIPasteboard.general.string = diagnosticDetail.formattedDescription
            }
#endif
            Button("OK", role: .cancel) {}
        } message: { diagnosticDetail in
            Text(diagnosticDetail.formattedDescription)
        }
#if os(iOS)
        .sheet(isPresented: $isFileImporterPresented) {
            ADBTVAPKDocumentPicker { result in
                isFileImporterPresented = false
                handlePackageSelection(result)
            }
        }
#else
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result.map({ $0.first }) {
            case .success(let url?):
                handlePackageSelection(.success(url))
            case .success(nil):
                break
            case .failure(let error):
                handlePackageSelection(.failure(error))
            }
        }
#endif
        .task(id: scenePhase) {
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }
            handleScenePhase(scenePhase)
        }
        .onDisappear {
            installTask?.cancel()
            remoteTask?.cancel()
            deviceConnectionTask?.cancel()
            model.cancelActiveDeviceOperation()
            cancelPairing()
            stopDiscovery()
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if (bonjourCapability.automaticallyStartsDiscovery
                && automaticDiscoveryPolicy.shouldStartDiscovery(status: model.discoveryStatus))
                || automaticDiscoveryPolicy.shouldResumeDiscovery(status: model.discoveryStatus)
                || automaticDiscoveryPolicy.shouldRetryAuthorizationFailureAfterActivation(
                    status: model.discoveryStatus
                ) {
                startDiscovery()
            }
        case .background:
            automaticDiscoveryPolicy.recordSceneLeftActiveState()
            if automaticDiscoveryPolicy.shouldSuspendDiscovery(status: model.discoveryStatus) {
                stopDiscovery()
            }
        case .inactive:
            automaticDiscoveryPolicy.recordSceneLeftActiveState()
        @unknown default:
            break
        }
    }

    private func handlePackageSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.pathExtension.lowercased() == "apk" else {
                model.failInstall(
                    userMessage: "Select an APK file.",
                    diagnosticDetail: DiagnosticDetail(
                        summary: "The selected file does not use the .apk extension.",
                        context: [
                            "fileName": url.lastPathComponent,
                            "source": "documentPicker"
                        ]
                    )
                )
                return
            }
            model.selectPackage(fileURL: url, byteCount: url.adbTVFileByteCount)
        case .failure(let error):
            model.failInstall(
                userMessage: "Could not open the selected APK.",
                diagnosticDetail: DiagnosticDetail(
                    summary: String(describing: error),
                    context: ["source": "documentPicker"]
                )
            )
        }
    }

    private func addDevice(_ device: ADBTVDeviceSummary) {
        model.addDevice(device)
        saveDevices()
    }

    private func replaceDeviceConnection(
        _ verifiedDevice: ADBTVDeviceSummary,
        replacing deviceID: ADBTVDeviceSummary.ID
    ) throws {
        var updatedModel = model
        try updatedModel.replaceDeviceConnection(id: deviceID, with: verifiedDevice)
        try deviceStore.saveDevices(updatedModel.devices)

        deviceConnectionTask?.cancel()
        deviceConnectionTask = nil
        deviceConnectionState = .idle
        model = updatedModel
    }

    private func selectSavedDevice(id: ADBTVDeviceSummary.ID?) {
        guard model.activeDeviceOperation == nil else {
            return
        }

        deviceConnectionTask?.cancel()
        deviceConnectionTask = nil

        guard let id,
              let device = model.devices.first(where: { $0.id == id }) else {
            deviceConnectionState = .idle
            _ = model.selectDevice(id: nil)
            return
        }

        if model.selectedDeviceID == id, deviceConnectionState == .idle {
            return
        }

        _ = model.selectDevice(id: nil)
        deviceConnectionState = .connecting(device)
        deviceConnectionTask = Task {
            do {
                let verifiedDevice = try await Self.verifySavedDevice(device)
                guard !Task.isCancelled,
                      deviceConnectionState.device?.id == device.id else {
                    return
                }
                deviceConnectionTask = nil
                deviceConnectionState = .idle
                model.addDevice(verifiedDevice)
                saveDevices()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      deviceConnectionState.device?.id == device.id else {
                    return
                }
                deviceConnectionTask = nil
                deviceConnectionState = .failed(
                    device: device,
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: Self.operationDiagnosticContext(
                            error: error,
                            base: [
                                "device": device.connectionDescription,
                                "operation": "verifySavedDevice"
                            ]
                        )
                    )
                )
            }
        }
    }

    private func deleteDevices(at offsets: IndexSet) {
        let ids = Set(offsets.map { model.devices[$0].id })
        if let connectionDeviceID = deviceConnectionState.device?.id,
           ids.contains(connectionDeviceID) {
            deviceConnectionTask?.cancel()
            deviceConnectionTask = nil
            deviceConnectionState = .idle
        }
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

    private static func deviceLoadDiagnosticDetail(
        for result: ADBTVDeviceStoreLoadResult
    ) -> DiagnosticDetail? {
        guard result.hasFailures else {
            return nil
        }

        var context = [
            "operation": "loadDevices",
            "recoveredDeviceCount": String(result.devices.count),
            "rejectedRecordCount": String(result.rejectedRecordCount)
        ]
        if result.rejectedRecordCount == 0 {
            context["reason"] = "invalidDeviceArchive"
        } else {
            context["reason"] = "partiallyInvalidDeviceArchive"
        }
        if let failureDescription = result.failureDescription {
            context["underlyingError"] = failureDescription
        }

        return DiagnosticDetail(
            summary: result.rejectedRecordCount == 0
                ? "Saved devices could not be loaded because the Device Library data is invalid."
                : "Some saved devices could not be loaded. Valid devices were recovered.",
            context: context
        )
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
        browser.start(updateHandler: { [weak browser] services in
            guard let browser, discoveryBrowser === browser else {
                return
            }
            if let device = model.updateDiscoveredServices(services) {
                pairingTask?.cancel()
                pairingTask = nil
                verifyPairingConnection(device)
            }
            if model.selectQRCodePairingServiceIfAvailable() {
                startPairing()
            }
        }, stateHandler: { [weak browser] state in
            guard let browser, discoveryBrowser === browser else {
                return
            }
            switch state {
            case .ready:
                automaticDiscoveryPolicy.recordDiscoveryReady()
                model.markDiscoveryReady()
            case .waitingForAuthorization(let failure):
                model.waitForLocalNetworkAuthorization(
                    userMessage: Self.discoveryWaitingUserMessage(for: failure),
                    diagnosticDetail: DiagnosticDetail(
                        summary: failure.diagnosticDescription,
                        context: Self.discoveryDiagnosticContext(for: failure)
                    )
                )
            }
        }, failureHandler: { [weak browser] failure in
            guard let browser, discoveryBrowser === browser else {
                return
            }
            browser.cancel()
            discoveryBrowser = nil
            if failure.reason == .localNetworkDenied {
                automaticDiscoveryPolicy.recordAuthorizationFailure()
            }
            model.failDiscovery(
                userMessage: Self.discoveryUserMessage(for: failure),
                diagnosticDetail: DiagnosticDetail(
                    summary: failure.diagnosticDescription,
                    context: Self.discoveryDiagnosticContext(for: failure)
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

#if canImport(Network)
    private static func discoveryUserMessage(for failure: ADBBonjourDiscoveryFailure) -> String {
        switch failure.reason {
        case .bonjourCapabilityDenied:
            return "Automatic discovery is unavailable in this signed build. Add the TV manually."
        case .localNetworkDenied:
            return "Local Network access is off. Enable it in Settings to discover Android TV devices."
        case .other:
            return "Could not discover Android TV devices."
        }
    }

    private static func discoveryWaitingUserMessage(
        for failure: ADBBonjourDiscoveryFailure
    ) -> String {
        switch failure.reason {
        case .bonjourCapabilityDenied:
            return "Automatic discovery requires an Apple-approved Multicast Networking entitlement."
        case .localNetworkDenied:
            return "Local Network access is off. Enable it in Settings to discover Android TV devices."
        case .other:
            return "Waiting for the local network before discovering Android TV devices."
        }
    }

    private static func discoveryDiagnosticContext(
        for failure: ADBBonjourDiscoveryFailure
    ) -> [String: String] {
        var context = [
            "operation": "bonjourDiscovery",
            "reason": failure.reason.rawValue,
            "operatingSystemVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            context["bundleIdentifier"] = bundleIdentifier
        }
#if os(iOS)
        let declaredServices = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        context["declaredBonjourServices"] = declaredServices?.joined(separator: ",") ?? "missing"
        context["localNetworkUsageDescription"] = Bundle.main.object(
            forInfoDictionaryKey: "NSLocalNetworkUsageDescription"
        ) == nil ? "missing" : "present"
#endif
        if let dnsErrorCode = failure.dnsErrorCode {
            context["dnsErrorCode"] = String(dnsErrorCode)
        }
        return context
    }
#endif

    private func prepareDiscoveredPairing(_ service: ADBDiscoveredService) {
        guard service.kind == .pairing, model.activeDeviceOperation == nil else {
            return
        }

        model.prepareDiscoveredPairing(service: service)
        isPairDevicePresented = true
    }

#if os(iOS) && canImport(AVFoundation)
    private func presentQRCodeScanner() {
        guard model.activeDeviceOperation == nil else {
            return
        }
        if !model.discoveryStatus.isBrowsing {
            startDiscovery()
        }
        isQRCodeScannerPresented = true
    }

    private func handleQRCodePayload(_ payload: String) {
        model.prepareQRCodePairing(payload: payload)
        isQRCodeScannerPresented = false
        isPairDevicePresented = true
        if model.selectQRCodePairingServiceIfAvailable() {
            startPairing()
        } else if let serviceName = model.pairingDraft.pairingQRCode?.serviceName {
            waitForPairingService(serviceName: serviceName)
        }
    }

    private func handleQRCodeScannerFailure(_ detail: DiagnosticDetail) {
        isQRCodeScannerPresented = false
        qrScannerError = detail
    }
#endif

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
        if let qrCode = draft.pairingQRCode,
           let service = draft.discoveredService {
            source = .qrCode
            target = qrCode.serviceName
            guard service.serviceName == qrCode.serviceName else {
                return
            }
        } else if let service = draft.discoveredService {
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
                if draft.pairingQRCode != nil {
                    completion = .discovered(
                        deviceGUID: try await Self.pairQRCode(using: draft),
                        displayName: draft.normalizedDisplayName
                    )
                } else if draft.discoveredService != nil {
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
                    userMessage: Self.pairingUserMessage(for: error),
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: Self.operationDiagnosticContext(
                            error: error,
                            base: [
                                "operation": "pairDevice",
                                "target": target
                            ]
                        )
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
        try await ADBTVOperationTimeoutPolicy.pairing.run(operation: .pairing) {
            try await ADBTVPairingOperation().pairManualCode(from: draft)
        }
#else
        throw ADBTVPairingViewError.unsupportedPlatform
#endif
    }

    private static func pairDiscoveredDevice(using draft: ADBTVPairingDraft) async throws -> String {
#if canImport(Network)
        try await ADBTVOperationTimeoutPolicy.pairing.run(operation: .pairing) {
            try await ADBTVPairingOperation().pairDiscoveredService(from: draft)
        }
#else
        throw ADBTVPairingViewError.unsupportedPlatform
#endif
    }

    private static func pairQRCode(using draft: ADBTVPairingDraft) async throws -> String {
#if canImport(Network)
        try await ADBTVOperationTimeoutPolicy.pairing.run(operation: .pairing) {
            try await ADBTVPairingOperation().pairQRCode(from: draft)
        }
#else
        throw ADBTVPairingViewError.unsupportedPlatform
#endif
    }

    @MainActor
    private func completePairing(_ completion: PairingCompletion) {
        pairingTask = nil
        switch completion {
        case .success(let device):
            verifyPairingConnection(device)
        case let .discovered(deviceGUID, displayName):
            if let device = model.waitForDiscoveredConnection(
                deviceGUID: deviceGUID,
                displayName: displayName
            ) {
                verifyPairingConnection(device)
            } else {
                waitForConnectionService(deviceGUID: deviceGUID)
            }
        case .failure(let userMessage, let diagnosticDetail):
            model.failPairing(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        }
    }

    @MainActor
    private func verifyPairingConnection(_ device: ADBTVDeviceSummary) {
        model.beginPairingConnectionVerification(device: device)
        pairingTask?.cancel()
        pairingTask = Task {
            do {
                let verifiedDevice = try await Self.verifyPairedDevice(device)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard !Task.isCancelled else {
                        return
                    }
                    if model.finishPairingConnectionVerification(
                        expectedDeviceID: device.id,
                        verifiedDevice: verifiedDevice
                    ) {
                        saveDevices()
                        pairingTask = nil
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard !Task.isCancelled else {
                        return
                    }
                    if model.failPairingConnectionVerification(
                        expectedDeviceID: device.id,
                        userMessage: "Pairing succeeded, but the app could not connect to the TV.",
                        diagnosticDetail: DiagnosticDetail(
                            summary: String(describing: error),
                            context: Self.operationDiagnosticContext(
                                error: error,
                                base: [
                                    "operation": "verifyPairedDevice",
                                    "target": device.connectionDescription
                                ]
                            )
                        )
                    ) {
                        pairingTask = nil
                    }
                }
            }
        }
    }

    @MainActor
    private func waitForPairingService(serviceName: String) {
        pairingTask?.cancel()
        pairingTask = Task {
            do {
                try await ADBTVOperationTimeoutPolicy.pairingServiceDiscovery.waitUntilTimedOut(
                    operation: .pairingServiceDiscovery
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard !Task.isCancelled else {
                        return
                    }
                    let didFailWaitingPairing = model.failWaitingForPairingService(
                        serviceName: serviceName,
                        userMessage: "The QR pairing service was not found on the local network.",
                        diagnosticDetail: DiagnosticDetail(
                            summary: String(describing: error),
                            context: Self.operationDiagnosticContext(
                                error: error,
                                base: [
                                    "operation": "findPairingService",
                                    "serviceName": serviceName
                                ]
                            )
                        )
                    )
                    if didFailWaitingPairing {
                        pairingTask = nil
                    }
                }
            }
        }
    }

    @MainActor
    private func waitForConnectionService(deviceGUID: String) {
        pairingTask?.cancel()
        pairingTask = Task {
            do {
                try await ADBTVOperationTimeoutPolicy.connectionServiceDiscovery.waitUntilTimedOut(
                    operation: .connectionServiceDiscovery
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard !Task.isCancelled else {
                        return
                    }
                    let didFailWaitingPairing = model.failWaitingForConnection(
                        deviceGUID: deviceGUID,
                        userMessage: "Pairing succeeded, but the TV connection service was not found.",
                        diagnosticDetail: DiagnosticDetail(
                            summary: String(describing: error),
                            context: Self.operationDiagnosticContext(
                                error: error,
                                base: [
                                    "deviceGUID": deviceGUID,
                                    "operation": "findConnectionService"
                                ]
                            )
                        )
                    )
                    if didFailWaitingPairing {
                        pairingTask = nil
                    }
                }
            }
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

    private static func pairingUserMessage(for error: Error) -> String {
        if error is ADBTVOperationTimeoutError {
            return "Pairing timed out. Check the TV and try again."
        }
        return "Could not pair with this Android TV."
    }

    private func startInstall(for device: ADBTVDeviceSummary) {
        let installModel = model
        guard model.startInstall(on: device.id) else {
            return
        }

        installTask?.cancel()
        installTask = Task {
            let completion: InstallCompletion
            do {
                completion = .success(try await Self.installPackage(
                    for: device,
                    using: installModel,
                    eventHandler: { event in
                        guard !Task.isCancelled else {
                            return
                        }
                        await MainActor.run {
                            guard !Task.isCancelled else {
                                return
                            }
                            model.recordInstallEvent(event, on: device.id)
                        }
                    }
                ))
            } catch let error as ADBTVInstallCancellationError {
                completion = .cancelled(
                    cleanupFailure: error.cleanupError.map {
                        Self.installCancellationCleanupDiagnosticDetail(
                            cleanupError: $0,
                            device: device
                        )
                    }
                )
            } catch is CancellationError {
                completion = .cancelled(cleanupFailure: nil)
            } catch {
                completion = .failure(
                    userMessage: Self.installUserMessage(for: error),
                    diagnosticDetail: Self.installDiagnosticDetail(error, device: device)
                )
            }

            await MainActor.run {
                completeInstall(completion, on: device.id)
            }
        }
    }

    private func installUnicodeInputHelper(on device: ADBTVDeviceSummary) {
        guard let packageURL = Bundle.main.url(
            forResource: "ADBTVInput",
            withExtension: "apk"
        ) else {
            model.failInstall(
                userMessage: "The Unicode Input Helper is missing from this app build.",
                diagnosticDetail: DiagnosticDetail(
                    summary: "The bundled ADBTVInput.apk resource was not found.",
                    context: ["operation": "installUnicodeInputHelper"]
                )
            )
            return
        }

        model.selectPackage(
            fileURL: packageURL,
            byteCount: packageURL.adbTVFileByteCount
        )
        startInstall(for: device)
    }

    private func cancelInstall() {
        guard case .install(let deviceID) = model.activeDeviceOperation else {
            return
        }
        guard model.beginCancellingInstall(on: deviceID) else {
            return
        }
        installTask?.cancel()
    }

    private static func installPackage(
        for device: ADBTVDeviceSummary,
        using installModel: ADBTVAppModel,
        eventHandler: @escaping ADBTVInstallEventHandler
    ) async throws -> ADBAPKInstallReport {
#if canImport(Network) && canImport(Security)
        let planRecorder = ADBTVPreparedInstallPlanRecorder()
        do {
            return try await ADBTVOperationTimeoutPolicy.apkInstallation.run(operation: .apkInstallation) {
                let operation = ADBTVInstallOperation()
                let package = try await operation.prepareSelectedPackage(
                    from: installModel,
                    eventHandler: eventHandler
                )
                await planRecorder.record(package.plan)
                var connection = try await connectedDevice(for: device)
                defer { connection.cancel() }
                return try await operation.installPreparedPackage(
                    package,
                    using: &connection,
                    eventHandler: eventHandler
                )
            }
        } catch {
            let preparedPlan = await planRecorder.recordedPlan()
            if Task.isCancelled {
                let cleanupError: String?
                if let preparedPlan {
                    cleanupError = await cleanupStagedPackageAfterInterruption(
                        plan: preparedPlan,
                        device: device
                    )
                } else {
                    cleanupError = nil
                }
                throw ADBTVInstallCancellationError(cleanupError: cleanupError)
            }
            if let timeoutError = error as? ADBTVOperationTimeoutError,
               let preparedPlan {
                if let cleanupError = await cleanupStagedPackageAfterInterruption(
                    plan: preparedPlan,
                    device: device
                ) {
                    throw ADBTVInstallTimeoutCleanupError(
                        timeoutError: timeoutError,
                        cleanupError: cleanupError
                    )
                }
            }
            throw error
        }
#else
        throw ADBTVInstallOperationError.unsupportedPlatform
#endif
    }

    @MainActor
    private func completeInstall(
        _ completion: InstallCompletion,
        on deviceID: ADBTVDeviceSummary.ID
    ) {
        installTask = nil
        switch completion {
        case .success(let report):
            model.finishInstall(result: report.result, on: deviceID)
        case .failure(let userMessage, let diagnosticDetail):
            model.failInstall(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail,
                on: deviceID
            )
        case .cancelled(let cleanupFailure):
            model.finishCancellingInstall(
                cleanupFailure: cleanupFailure,
                on: deviceID
            )
        }
    }

#if canImport(Network) && canImport(Security)
    private static func cleanupStagedPackageAfterInterruption(
        plan: ADBAPKInstallPlan,
        device: ADBTVDeviceSummary
    ) async -> String? {
        await Task.detached { () -> String? in
            do {
                try await ADBTVOperationTimeoutPolicy.apkStagingCleanup.run(
                    operation: .apkStagingCleanup
                ) {
                    var connection = try await connectedDevice(for: device)
                    defer { connection.cancel() }
                    try await ADBAPKStagingCleaner().cleanup(
                        plan: plan,
                        using: &connection
                    )
                }
                return nil
            } catch {
                return String(describing: error)
            }
        }.value
    }
#endif

    private static func installCancellationCleanupDiagnosticDetail(
        cleanupError: String,
        device: ADBTVDeviceSummary
    ) -> DiagnosticDetail {
        DiagnosticDetail(
            summary: cleanupError,
            context: [
                "device": device.connectionDescription,
                "operation": "cleanupCancelledAPK",
                "phase": "cleanup"
            ]
        )
    }

    private static func installDiagnosticDetail(_ error: Error, device: ADBTVDeviceSummary) -> DiagnosticDetail {
        var context = [
            "device": device.connectionDescription,
            "operation": "installAPK"
        ]
        if error is ADBAPKValidationError || error is ADBTVInstallFileError {
            context["phase"] = "validatePackage"
        }
        if error is ADBTVInstallDownloadError {
            context["phase"] = "downloadPackage"
        }
        context = operationDiagnosticContext(error: error, base: context)

        if let recoveryError = error as? ADBTVInstallTimeoutCleanupError {
            if case let .timedOut(operation, seconds) = recoveryError.timeoutError {
                context["timedOperation"] = operation.rawValue
                context["timeoutSeconds"] = String(seconds)
            }
            context["cleanupError"] = recoveryError.cleanupError
        }

        let summary = (error as? ADBTVInstallTimeoutCleanupError).map {
            String(describing: $0.timeoutError)
        } ?? String(describing: error)
        return DiagnosticDetail(
            summary: summary,
            context: context
        )
    }

    private static func installUserMessage(for error: Error) -> String {
        if error is ADBTVOperationTimeoutError || error is ADBTVInstallTimeoutCleanupError {
            return "APK installation timed out."
        }
        if error is ADBAPKValidationError {
            return "The selected file is not a valid APK."
        }
        if error is ADBTVInstallFileError {
            return "Could not read the selected APK."
        }
        if error is ADBTVInstallDownloadError {
            return "Could not download APK."
        }

        return "Could not install APK."
    }

    private func sendRemoteAction(_ action: ADBTVRemoteAction, to device: ADBTVDeviceSummary) {
        let remoteModel = model
        guard model.recordRemoteActionStarted(action, on: device.id) else {
            return
        }

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
                    userMessage: Self.remoteUserMessage(for: error),
                    diagnosticDetail: Self.remoteDiagnosticDetail(error, action: action, device: device)
                )
            }

            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                completeRemoteAction(completion, on: device.id)
            }
        }
    }

    private func sendRemoteText(to device: ADBTVDeviceSummary) {
        guard let text = model.remoteText else {
            return
        }

        let remoteModel = model
        guard model.recordRemoteTextStarted(on: device.id) else {
            return
        }

        remoteTask?.cancel()
        remoteTask = Task {
            let completion: RemoteCompletion
            do {
                _ = try await Self.sendRemoteText(
                    text,
                    to: device,
                    using: remoteModel
                )
                completion = .textSuccess
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                completion = .textFailure(
                    userMessage: Self.remoteTextUserMessage(for: error),
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: Self.operationDiagnosticContext(
                            error: error,
                            base: [
                                "device": device.connectionDescription,
                                "operation": "sendRemoteText"
                            ]
                        )
                    )
                )
            }

            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                completeRemoteAction(completion, on: device.id)
            }
        }
    }

    private func cancelRemoteOperation() {
        guard let activeDeviceOperation = model.activeDeviceOperation else {
            return
        }
        switch activeDeviceOperation {
        case .remoteAction, .remoteText:
            remoteTask?.cancel()
            remoteTask = nil
            model.cancelActiveDeviceOperation()
        case .install:
            return
        }
    }

    private static func sendRemoteAction(
        _ action: ADBTVRemoteAction,
        to device: ADBTVDeviceSummary,
        using remoteModel: ADBTVAppModel
    ) async throws -> ADBShellOutput {
#if canImport(Network) && canImport(Security)
        return try await ADBTVOperationTimeoutPolicy.remoteAction.run(operation: .remoteAction) {
            var connection = try await connectedDevice(for: device)
            defer { connection.cancel() }
            return try await ADBTVRemoteOperation().sendAction(
                action,
                from: remoteModel,
                using: &connection
            )
        }
#else
        throw ADBTVRemoteOperationError.unsupportedPlatform
#endif
    }

    private static func sendRemoteText(
        _ text: ADBTVRemoteText,
        to device: ADBTVDeviceSummary,
        using remoteModel: ADBTVAppModel
    ) async throws -> ADBShellOutput {
#if canImport(Network) && canImport(Security)
        return try await ADBTVOperationTimeoutPolicy.remoteAction.run(operation: .remoteAction) {
            var connection = try await connectedDevice(for: device)
            defer { connection.cancel() }
            return try await ADBTVRemoteOperation().sendText(
                text,
                from: remoteModel,
                using: &connection
            )
        }
#else
        throw ADBTVRemoteOperationError.unsupportedPlatform
#endif
    }

#if canImport(Network) && canImport(Security)
    private static func connectedDevice(
        for device: ADBTVDeviceSummary
    ) async throws -> ADBDeviceConnection {
        try await ADBTVOperationTimeoutPolicy.deviceConnection.run(operation: .deviceConnection) {
            try await ADBDeviceConnection.connectedToWirelessDebugging(
                target: device.networkTarget()
            )
        }
    }

    private static func verifyManualDevice(
        _ device: ADBTVDeviceSummary
    ) async throws -> ADBTVDeviceSummary {
        try await verifyDevice(
            device,
            timeout: ADBTVOperationTimeoutPolicy.manualDeviceVerification,
            operation: .manualDeviceVerification
        )
    }

    private static func verifySavedDevice(
        _ device: ADBTVDeviceSummary
    ) async throws -> ADBTVDeviceSummary {
        try await verifyDevice(
            device,
            timeout: ADBTVOperationTimeoutPolicy.savedDeviceVerification,
            operation: .savedDeviceVerification
        )
    }

    private static func verifyPairedDevice(
        _ device: ADBTVDeviceSummary
    ) async throws -> ADBTVDeviceSummary {
        try await verifyDevice(
            device,
            timeout: ADBTVOperationTimeoutPolicy.pairingConnectionVerification,
            operation: .pairingConnectionVerification
        )
    }

    private static func verifyDevice(
        _ device: ADBTVDeviceSummary,
        timeout: ADBTVOperationTimeout,
        operation: ADBTVTimedOperation
    ) async throws -> ADBTVDeviceSummary {
        try await timeout.run(operation: operation) {
            var connection = try await connectedDevice(for: device)
            defer { connection.cancel() }

            _ = try await connection.connect()
            let invocation = try ADBDeviceProperty.model.shellInvocation()
            let output = try await connection.runShellCommand(invocation.shellCommand)
            let model = try invocation.validatedOutput(from: output)
                .utf8String
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var verifiedDevice = device
            verifiedDevice.model = model.isEmpty ? nil : model
            return verifiedDevice
        }
    }
#else
    private static func verifyManualDevice(
        _ device: ADBTVDeviceSummary
    ) async throws -> ADBTVDeviceSummary {
        throw ADBTVManualDeviceError.unsupportedPlatform
    }

    private static func verifySavedDevice(
        _ device: ADBTVDeviceSummary
    ) async throws -> ADBTVDeviceSummary {
        throw ADBTVManualDeviceError.unsupportedPlatform
    }

    private static func verifyPairedDevice(
        _ device: ADBTVDeviceSummary
    ) async throws -> ADBTVDeviceSummary {
        throw ADBTVManualDeviceError.unsupportedPlatform
    }
#endif

    @MainActor
    private func completeRemoteAction(
        _ completion: RemoteCompletion,
        on deviceID: ADBTVDeviceSummary.ID
    ) {
        remoteTask = nil
        switch completion {
        case .success(let action):
            model.finishRemoteAction(action, on: deviceID)
        case .textSuccess:
            model.finishRemoteText(on: deviceID)
        case .failure(let action, let userMessage, let diagnosticDetail):
            model.failRemoteAction(
                action,
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail,
                on: deviceID
            )
        case .textFailure(let userMessage, let diagnosticDetail):
            model.failRemoteText(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail,
                on: deviceID
            )
        }
    }

    private static func remoteDiagnosticDetail(
        _ error: Error,
        action: ADBTVRemoteAction,
        device: ADBTVDeviceSummary
    ) -> DiagnosticDetail {
        DiagnosticDetail(
            summary: String(describing: error),
            context: operationDiagnosticContext(
                error: error,
                base: [
                    "action": action.displayTitle,
                    "device": device.connectionDescription,
                    "operation": "sendRemoteAction"
                ]
            )
        )
    }

    private static func remoteUserMessage(for error: Error) -> String {
        error is ADBTVOperationTimeoutError
            ? "The TV did not respond in time."
            : "Could not send remote action."
    }

    private static func remoteTextUserMessage(for error: Error) -> String {
        if error is ADBTVOperationTimeoutError {
            return "The TV did not respond in time."
        }
        if let shellError = error as? ADBTVRemoteShellInvocationError,
           case let .commandFailed(exitCode, _) = shellError {
            if (21 ... 22).contains(exitCode) {
                return "Install the Unicode Input Helper, then try sending the text again."
            }
            if exitCode == 24 {
                return "Could not restore the previous TV keyboard. Select it in the TV settings."
            }
            if exitCode == 23 || exitCode == 25 {
                return "Focus a text field on the TV, then try sending the Unicode text again."
            }
        }
        return "Could not send text."
    }

    private static func operationDiagnosticContext(
        error: Error,
        base: [String: String]
    ) -> [String: String] {
        var context = base
        if case let ADBTVOperationTimeoutError.timedOut(operation, seconds) = error {
            context["timedOperation"] = operation.rawValue
            context["timeoutSeconds"] = String(seconds)
        }
        return context
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

private enum ADBTVManualDeviceError: Error {
    case unsupportedPlatform
}

private enum InstallCompletion: Sendable {
    case success(ADBAPKInstallReport)
    case failure(userMessage: String, diagnosticDetail: DiagnosticDetail)
    case cancelled(cleanupFailure: DiagnosticDetail?)
}

private struct ADBTVInstallCancellationError: Error, Sendable {
    var cleanupError: String?
}

private struct ADBTVInstallTimeoutCleanupError: Error, Sendable {
    var timeoutError: ADBTVOperationTimeoutError
    var cleanupError: String
}

private actor ADBTVPreparedInstallPlanRecorder {
    private var plan: ADBAPKInstallPlan?

    func record(_ plan: ADBAPKInstallPlan) {
        self.plan = plan
    }

    func recordedPlan() -> ADBAPKInstallPlan? {
        plan
    }
}

private enum RemoteCompletion: Sendable {
    case success(ADBTVRemoteAction)
    case textSuccess
    case failure(action: ADBTVRemoteAction, userMessage: String, diagnosticDetail: DiagnosticDetail)
    case textFailure(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

private struct ADBTVAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version", value: versionDescription)
                }

                Section("Legal") {
                    NavigationLink {
                        ADBTVOpenSourceNoticesView()
                    } label: {
                        Label("Licenses & Notices", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("About ADB TV")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .help("Close")
                }
            }
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return build
        case (nil, nil):
            return "Unknown"
        }
    }
}

private struct ADBTVOpenSourceNoticesView: View {
    var body: some View {
        ScrollView {
            Text(ADBTVOpenSourceNotices.text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Licenses & Notices")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
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
                    if let qrCode = draft.pairingQRCode {
                        LabeledContent("Service", value: qrCode.serviceName)
                    } else if let service = draft.discoveredService {
                        LabeledContent("Service", value: service.displayName)
                    } else {
                        TextField("Host or IP Address", text: $draft.host)
                            .autocorrectionDisabled()
                        TextField("Connection Port", text: $draft.connectionPortString)
                    }
                }

                if draft.pairingQRCode == nil {
                    Section("Pairing") {
                        if draft.discoveredService == nil {
                            TextField("Pairing Port", text: $draft.pairingPortString)
                        }
                        TextField("6-Digit Code", text: $draft.codeString)
                    }
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

                if !hasPaired && draft.pairingQRCode == nil {
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
        case .waitingForPairingService(let serviceName):
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding the pairing service")
                        .foregroundStyle(.secondary)
                }
                Text(serviceName)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
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
        case .verifyingConnection(let device):
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Verifying the TV connection")
                        .foregroundStyle(.secondary)
                }
                Text(device.connectionDescription)
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
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        }
    }
}

private func connectionUserMessage(for error: Error, fallback: String) -> String {
    error is ADBTVOperationTimeoutError
        ? "The TV did not respond in time."
        : fallback
}

private func connectionDiagnosticContext(
    error: Error,
    base: [String: String]
) -> [String: String] {
    var context = base
    if case let ADBTVOperationTimeoutError.timedOut(operation, seconds) = error {
        context["timedOperation"] = operation.rawValue
        context["timeoutSeconds"] = String(seconds)
    }
    return context
}

private struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var host = ""
    @State private var port = "5555"
    @State private var status: ManualDeviceConnectionStatus = .idle
    @State private var connectionTask: Task<Void, Never>?

    var verifyDevice: (ADBTVDeviceSummary) async throws -> ADBTVDeviceSummary
    var addDevice: (ADBTVDeviceSummary) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Name", text: $displayName)
                    TextField("Host", text: $host)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                }
                .disabled(status.isConnecting || status.isConnected)

                ManualDeviceConnectionStatusView(status: status)
            }
            .navigationTitle("Add Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(status.isConnected ? "Close" : "Cancel") {
                        connectionTask?.cancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if !status.isConnected {
                        Button("Connect & Save") {
                            connectAndSave()
                        }
                        .disabled(validatedDevice == nil || status.isConnecting)
                    }
                }
            }
        }
        .interactiveDismissDisabled(status.isConnecting)
        .onDisappear {
            connectionTask?.cancel()
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

    private func connectAndSave() {
        guard let device = validatedDevice else {
            return
        }

        connectionTask?.cancel()
        status = .connecting
        connectionTask = Task {
            do {
                let verifiedDevice = try await verifyDevice(device)
                guard !Task.isCancelled else {
                    return
                }
                addDevice(verifiedDevice)
                status = .connected(verifiedDevice)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                status = .failed(
                    userMessage: connectionUserMessage(
                        for: error,
                        fallback: "Could not connect to this Android TV device."
                    ),
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: connectionDiagnosticContext(
                            error: error,
                            base: [
                                "device": device.connectionDescription,
                                "operation": "verifyManualDevice"
                            ]
                        )
                    )
                )
            }
        }
    }
}

private enum ManualDeviceConnectionStatus: Equatable {
    case idle
    case connecting
    case connected(ADBTVDeviceSummary)
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    var isConnecting: Bool {
        if case .connecting = self {
            return true
        }
        return false
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

private struct ManualDeviceConnectionStatusView: View {
    var status: ManualDeviceConnectionStatus

    @ViewBuilder
    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .connecting:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting")
                        .foregroundStyle(.secondary)
                }
            }
        case .connected(let device):
            Section {
                Label("Connected and saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Device", value: device.model ?? device.displayName)
            }
        case .failed(let userMessage, let diagnosticDetail):
            Section {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        }
    }
}

private struct DiscoveryContent: View {
    var status: ADBTVDiscoveryStatus
    var services: [ADBDiscoveredService]
    var canPair: Bool
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
                .disabled(service.kind == .pairing && !canPair)
            }
        }
    }
}

private struct DiscoveryStatusView: View {
#if os(iOS)
    @Environment(\.openURL) private var openURL
#endif

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
        case .waitingForLocalNetworkAuthorization(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 6) {
                Label(userMessage, systemImage: "lock.shield")
                    .foregroundStyle(.orange)
#if os(iOS)
                settingsButton
#endif
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        case .failed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 6) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
#if os(iOS)
                if diagnosticDetail.context["reason"] == ADBBonjourDiscoveryFailure.Reason.localNetworkDenied.rawValue {
                    settingsButton
                }
#endif
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        }
    }

#if os(iOS)
    private var settingsButton: some View {
        Button {
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            openURL(settingsURL)
        } label: {
            Label("Open Settings", systemImage: "gear")
        }
    }
#endif
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

private enum ADBTVSavedDeviceConnectionState: Equatable {
    case idle
    case connecting(ADBTVDeviceSummary)
    case failed(device: ADBTVDeviceSummary, diagnosticDetail: DiagnosticDetail)

    var device: ADBTVDeviceSummary? {
        switch self {
        case .idle:
            return nil
        case .connecting(let device), .failed(let device, _):
            return device
        }
    }

    var isConnecting: Bool {
        if case .connecting = self {
            return true
        }
        return false
    }
}

private struct SavedDeviceConnectionView: View {
    var device: ADBTVDeviceSummary
    var state: ADBTVSavedDeviceConnectionState
    var retry: () -> Void
    var repair: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeviceHeader(device: device)

                switch state {
                case .idle:
                    EmptyView()
                case .connecting:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Connecting and verifying")
                            .foregroundStyle(.secondary)
                    }
                case .failed(_, let diagnosticDetail):
                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            "Could not connect to this TV.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)

                        Button(action: retry) {
                            Label("Retry Connection", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: repair) {
                            Label("Update Connection", systemImage: "network")
                        }
                        .buttonStyle(.bordered)

                        DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding()
        }
        .navigationTitle(device.displayName)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct RepairDeviceConnectionView: View {
    @Environment(\.dismiss) private var dismiss

    let device: ADBTVDeviceSummary
    @State private var host: String
    @State private var port: String
    @State private var status = RepairDeviceConnectionStatus.idle
    @State private var verificationTask: Task<Void, Never>?
    @State private var confirmsDifferentModel = false

    var verifyDevice: (ADBTVDeviceSummary) async throws -> ADBTVDeviceSummary
    var saveDevice: (ADBTVDeviceSummary) throws -> Void

    init(
        device: ADBTVDeviceSummary,
        verifyDevice: @escaping (ADBTVDeviceSummary) async throws -> ADBTVDeviceSummary,
        saveDevice: @escaping (ADBTVDeviceSummary) throws -> Void
    ) {
        self.device = device
        self.verifyDevice = verifyDevice
        self.saveDevice = saveDevice
        switch device.connection {
        case .hostPort(let host, let port):
            self._host = State(initialValue: host)
            self._port = State(initialValue: String(port))
        case .bonjour:
            self._host = State(initialValue: "")
            self._port = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Saved Device") {
                    LabeledContent("Name", value: device.displayName)
                    LabeledContent("Current Connection", value: device.connectionDescription)
                    if let model = device.model {
                        LabeledContent("Expected Model", value: model)
                    }
                }

                Section("New Connection") {
                    TextField("Host or IP Address", text: $host)
                        .autocorrectionDisabled()
                    TextField("Connection Port", text: $port)
                }
                .disabled(status.isVerifying)

                if status.verifiedDevice == nil {
                    Section {
                        Button {
                            testConnection()
                        } label: {
                            Label("Test Connection", systemImage: "network")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(candidateDevice == nil || status.isVerifying)
                    }
                }

                RepairDeviceConnectionStatusView(
                    status: status,
                    warnsAboutDifferentModel: status.verifiedDevice.map(modelDiffers) ?? false
                )
            }
            .navigationTitle("Update Connection")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        verificationTask?.cancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if let verifiedDevice = status.verifiedDevice {
                        Button("Save") {
                            if modelDiffers(from: verifiedDevice) {
                                confirmsDifferentModel = true
                            } else {
                                save(verifiedDevice)
                            }
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(status.isVerifying)
        .onChange(of: host) { _, _ in resetVerification() }
        .onChange(of: port) { _, _ in resetVerification() }
        .onDisappear { verificationTask?.cancel() }
        .confirmationDialog(
            "This looks like a different TV",
            isPresented: $confirmsDifferentModel,
            presenting: status.verifiedDevice
        ) { verifiedDevice in
            Button("Use This Connection", role: .destructive) {
                save(verifiedDevice)
            }
            Button("Cancel", role: .cancel) {}
        } message: { verifiedDevice in
            Text(
                "The saved model is \(device.model ?? "unknown"), but this endpoint reports "
                    + "\(verifiedDevice.model ?? "an unknown model")."
            )
        }
    }

    private var candidateDevice: ADBTVDeviceSummary? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty,
              let portValue = UInt16(normalizedPort),
              portValue > 0 else {
            return nil
        }

        return ADBTVDeviceSummary(
            id: device.id,
            displayName: device.displayName,
            host: normalizedHost,
            port: Int(portValue),
            model: device.model
        )
    }

    private func testConnection() {
        guard let candidateDevice else {
            return
        }

        verificationTask?.cancel()
        status = .verifying
        verificationTask = Task {
            do {
                let verifiedDevice = try await verifyDevice(candidateDevice)
                guard !Task.isCancelled else {
                    return
                }
                status = .verified(verifiedDevice)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                status = .failed(
                    userMessage: connectionUserMessage(
                        for: error,
                        fallback: "Could not verify this connection."
                    ),
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: connectionDiagnosticContext(
                            error: error,
                            base: [
                                "device": candidateDevice.connectionDescription,
                                "operation": "testReplacementConnection"
                            ]
                        )
                    )
                )
            }
        }
    }

    private func save(_ verifiedDevice: ADBTVDeviceSummary) {
        do {
            try saveDevice(verifiedDevice)
            dismiss()
        } catch {
            status = .failed(
                userMessage: saveFailureMessage(for: error),
                diagnosticDetail: DiagnosticDetail(
                    summary: String(describing: error),
                    context: [
                        "device": verifiedDevice.connectionDescription,
                        "operation": "saveReplacementConnection"
                    ]
                )
            )
        }
    }

    private func resetVerification() {
        guard !status.isVerifying else {
            return
        }
        status = .idle
    }

    private func modelDiffers(from verifiedDevice: ADBTVDeviceSummary) -> Bool {
        guard let expected = device.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty,
              let detected = verifiedDevice.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detected.isEmpty else {
            return false
        }
        return expected.caseInsensitiveCompare(detected) != .orderedSame
    }

    private func saveFailureMessage(for error: Error) -> String {
        if case let ADBTVDeviceRepairError.endpointAlreadySaved(displayName) = error {
            return "This connection is already saved as \(displayName)."
        }
        return "Could not save the updated connection."
    }
}

private enum RepairDeviceConnectionStatus: Equatable {
    case idle
    case verifying
    case verified(ADBTVDeviceSummary)
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    var isVerifying: Bool {
        if case .verifying = self {
            return true
        }
        return false
    }

    var verifiedDevice: ADBTVDeviceSummary? {
        guard case .verified(let device) = self else {
            return nil
        }
        return device
    }
}

private struct RepairDeviceConnectionStatusView: View {
    var status: RepairDeviceConnectionStatus
    var warnsAboutDifferentModel: Bool

    @ViewBuilder
    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .verifying:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Testing connection")
                        .foregroundStyle(.secondary)
                }
            }
        case .verified(let device):
            Section("Verified Device") {
                Label("Connection verified", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Detected Model", value: device.model ?? "Unknown")
                LabeledContent("Connection", value: device.connectionDescription)
                if warnsAboutDifferentModel {
                    Label(
                        "The detected model differs from the saved device.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
        case .failed(let userMessage, let diagnosticDetail):
            Section {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        }
    }
}

private struct DeviceDetailView: View {
    var device: ADBTVDeviceSummary
    var installDraft: ADBTVInstallDraft
    var installURLString: Binding<String>
    var remoteStatus: ADBTVRemoteStatus
    var remoteTextString: Binding<String>
    var canInstall: Bool
    var canSendRemoteText: Bool
    var deviceOperationInProgress: Bool
    var chooseAPK: () -> Void
    var install: () -> Void
    var cancelInstall: () -> Void
    var sendRemoteAction: (ADBTVRemoteAction) -> Void
    var sendRemoteText: () -> Void
    var cancelRemoteOperation: () -> Void
    var installUnicodeInputHelper: () -> Void

    @State private var selectedTool = ProcessInfo.processInfo.arguments.contains("--ui-install")
        ? DeviceTool.install
        : DeviceTool.remote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeviceHeader(device: device)

                Picker("Device Tool", selection: $selectedTool) {
                    ForEach(DeviceTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.systemImage)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)

                switch selectedTool {
                case .remote:
                    remotePanel
                case .install:
                    installPanel
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding()
        }
        .navigationTitle(device.displayName)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var installPanel: some View {
        APKInstallPanel(
            installDraft: installDraft,
            installURLString: installURLString,
            canInstall: canInstall,
            deviceOperationInProgress: deviceOperationInProgress,
            chooseAPK: chooseAPK,
            install: install,
            cancelInstall: cancelInstall
        )
    }

    private var remotePanel: some View {
        RemoteActionsPanel(
            status: remoteStatus,
            text: remoteTextString,
            canSendText: canSendRemoteText,
            deviceOperationInProgress: deviceOperationInProgress,
            unicodeHelperInstallStatus: unicodeHelperInstallStatus,
            send: sendRemoteAction,
            sendText: sendRemoteText,
            cancelRemoteOperation: cancelRemoteOperation,
            installUnicodeInputHelper: installUnicodeInputHelper
        )
    }

    private var unicodeHelperInstallStatus: ADBTVInstallStatus? {
        guard installDraft.selectedPackage?.fileName == ADBTVUnicodeInputHelper.bundledAPKFileName else {
            return nil
        }
        return installDraft.status
    }
}

private enum DeviceTool: String, CaseIterable, Identifiable {
    case remote
    case install

    var id: Self { self }

    var title: String {
        switch self {
        case .remote:
            return "Remote"
        case .install:
            return "Install"
        }
    }

    var systemImage: String {
        switch self {
        case .remote:
            return "gamecontroller"
        case .install:
            return "square.and.arrow.down"
        }
    }
}

private struct DeviceHeader: View {
    var device: ADBTVDeviceSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let model = device.model {
                    Text(model)
                        .font(.headline)
                }
                Text(device.connectionDescription)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "tv")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private struct APKInstallPanel: View {
    var installDraft: ADBTVInstallDraft
    var installURLString: Binding<String>
    var canInstall: Bool
    var deviceOperationInProgress: Bool
    var chooseAPK: () -> Void
    var install: () -> Void
    var cancelInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install APK")
                .font(.title2.bold())

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    chooseButton
                    installButton
                    if installDraft.status.canCancel {
                        cancelButton
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        chooseButton
                        installButton
                    }
                    if installDraft.status.canCancel {
                        cancelButton
                    }
                }
            }

            TextField("https://example.com/app.apk", text: installURLString)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(installDraft.status.isRunning || deviceOperationInProgress)

            if !installURLString.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !installDraft.canBuildInstallPlan {
                Label("Enter a direct HTTP or HTTPS APK URL", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            if let package = installDraft.selectedPackage {
                LabeledContent("Package") {
                    Text(package.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let byteCount = package.byteCount {
                    LabeledContent("Size", value: Self.formattedByteCount(byteCount))
                }
                if let fileURL = package.fileURL {
                    LabeledContent("Source") {
                        Text(fileURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else if let url = installDraft.validatedURL {
                LabeledContent("Source") {
                    Text(url.absoluteString)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            if installDraft.usesInsecureHTTP {
                Label(
                    "HTTP downloads are not protected in transit.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            InstallStatusView(status: installDraft.status)
        }
    }

    private var chooseButton: some View {
        Button {
            chooseAPK()
        } label: {
            Label("Choose APK", systemImage: "doc.badge.plus")
        }
        .buttonStyle(.bordered)
        .disabled(installDraft.status.isRunning || deviceOperationInProgress)
    }

    private var installButton: some View {
        Button {
            install()
        } label: {
            Label("Install", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(Color.white)
        .disabled(!canInstall || installDraft.status.isRunning || deviceOperationInProgress)
    }

    private var cancelButton: some View {
        Button(role: .cancel) {
            cancelInstall()
        } label: {
            Label("Cancel", systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
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
        case .downloading(let receivedByteCount, let totalByteCount):
            VStack(alignment: .leading, spacing: 8) {
                if let totalByteCount, totalByteCount > 0 {
                    ProgressView(value: progressFraction(receivedByteCount, totalByteCount))
                    Text("\(receivedByteCount) of \(totalByteCount) bytes")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("\(receivedByteCount) bytes received")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Label("Downloading APK", systemImage: "arrow.down.doc")
                    .foregroundStyle(.secondary)
            }
        case .transferring(let sentByteCount, let totalByteCount):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: transferFraction(sentByteCount, totalByteCount))
                Label("Transferring APK", systemImage: "arrow.up.doc")
                    .foregroundStyle(.secondary)
                Text("\(sentByteCount) of \(totalByteCount) bytes")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .cancelling:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                Label("Cancelling and cleaning up", systemImage: "trash")
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Label("Installation cancelled", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .cancelledWithCleanupFailure(let diagnosticDetail):
            VStack(alignment: .leading, spacing: 8) {
                Label("Installation cancelled, but device cleanup failed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        case .failed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 8) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
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

    private func transferFraction(_ sentByteCount: Int, _ totalByteCount: Int) -> Double {
        progressFraction(Int64(sentByteCount), Int64(totalByteCount))
    }

    private func progressFraction(_ completedByteCount: Int64, _ totalByteCount: Int64) -> Double {
        guard totalByteCount > 0 else {
            return 1
        }

        return min(max(Double(completedByteCount) / Double(totalByteCount), 0), 1)
    }
}

private struct RemoteActionsPanel: View {
    var status: ADBTVRemoteStatus
    var text: Binding<String>
    var canSendText: Bool
    var deviceOperationInProgress: Bool
    var unicodeHelperInstallStatus: ADBTVInstallStatus?
    var send: (ADBTVRemoteAction) -> Void
    var sendText: () -> Void
    var cancelRemoteOperation: () -> Void
    var installUnicodeInputHelper: () -> Void

    @State private var isMediaControlsExpanded = ProcessInfo.processInfo.arguments.contains(
        "--ui-media-expanded"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 16) {
                HStack {
                    roundButton(.power, systemImage: "power", foregroundStyle: .red)
                    Spacer()
                    roundButton(.menu, systemImage: "list.bullet")
                    Spacer()
                    roundButton(.home, systemImage: "house.fill")
                }

                directionalPad

                Button {
                    send(.back)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.title2.weight(.semibold))
                        .frame(width: 152, height: 44)
                        .background(controlBackground, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                HStack {
                    roundButton(.volumeDown, systemImage: "speaker.minus.fill")
                    Spacer()
                    roundButton(.volumeMute, systemImage: "speaker.slash.fill")
                    Spacer()
                    roundButton(.settings, systemImage: "gearshape.fill")
                    Spacer()
                    roundButton(.volumeUp, systemImage: "speaker.plus.fill")
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .disabled(status.isSending || deviceOperationInProgress)

            Divider()

            DisclosureGroup(isExpanded: $isMediaControlsExpanded) {
                mediaControls
                    .padding(.top, 12)
            } label: {
                Label("Media Controls", systemImage: "play.rectangle")
                    .font(.headline)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Text Input")
                    .font(.headline)

                HStack(spacing: 8) {
                    TextField("Type text to send", text: text)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .disabled(deviceOperationInProgress)
                    Button {
                        sendText()
                    } label: {
                        Label("Send Text", systemImage: "paperplane.fill")
                            .labelStyle(.iconOnly)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.white)
                    .disabled(!canSendText)
                    .accessibilityLabel("Send Text")
                }

                if text.wrappedValue.unicodeScalars.contains(where: { !$0.isASCII }) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            unicodeHelperLabel
                            Spacer(minLength: 8)
                            unicodeHelperButton
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            unicodeHelperLabel
                            unicodeHelperButton
                        }
                    }

                    if let unicodeHelperInstallStatus {
                        InstallStatusView(status: unicodeHelperInstallStatus)
                    }
                }
            }

            RemoteStatusView(
                status: status,
                cancel: cancelRemoteOperation
            )
        }
    }

    private var directionalPad: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.10))

                directionButton(.up, systemImage: "chevron.up")
                    .position(x: size / 2, y: size * 0.18)
                directionButton(.left, systemImage: "chevron.left")
                    .position(x: size * 0.18, y: size / 2)
                directionButton(.right, systemImage: "chevron.right")
                    .position(x: size * 0.82, y: size / 2)
                directionButton(.down, systemImage: "chevron.down")
                    .position(x: size / 2, y: size * 0.82)

                Button {
                    send(.select)
                } label: {
                    Text("OK")
                        .font(.title3.bold())
                        .frame(width: 76, height: 76)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .accessibilityLabel("Select")
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 248)
        .frame(maxWidth: .infinity)
    }

    private var controlBackground: Color {
        Color.secondary.opacity(0.14)
    }

    private var mediaControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                mediaButton(.mediaPrevious, systemImage: "backward.end.fill", title: "Prev")
                Spacer(minLength: 4)
                mediaButton(.mediaRewind, systemImage: "backward.fill", title: "Rew")
                Spacer(minLength: 4)
                mediaButton(.mediaPlayPause, systemImage: "playpause.fill", title: "Play")
                Spacer(minLength: 4)
                mediaButton(.mediaFastForward, systemImage: "forward.fill", title: "FF")
                Spacer(minLength: 4)
                mediaButton(.mediaNext, systemImage: "forward.end.fill", title: "Next")
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                mediaButton(.mediaStop, systemImage: "stop.fill", title: "Stop", tint: .red)
                Spacer(minLength: 12)
                mediaButton(.enter, systemImage: "return", title: "Enter")
                Spacer(minLength: 12)
                mediaButton(.delete, systemImage: "delete.left.fill", title: "Delete")
                Spacer(minLength: 12)
                mediaButton(.tab, systemImage: "arrow.right.to.line", title: "Tab")
                Spacer(minLength: 0)
            }
        }
        .disabled(status.isSending || deviceOperationInProgress)
    }

    private func mediaButton(
        _ action: ADBTVRemoteAction,
        systemImage: String,
        title: String,
        tint: Color = .primary
    ) -> some View {
        Button {
            send(action)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(width: 54, height: 58)
            .background(controlBackground, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.displayTitle)
    }

    private func directionButton(
        _ action: ADBTVRemoteAction,
        systemImage: String
    ) -> some View {
        Button {
            send(action)
        } label: {
            Image(systemName: systemImage)
                .font(.title2.weight(.bold))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.displayTitle)
    }

    private func roundButton(
        _ action: ADBTVRemoteAction,
        systemImage: String,
        foregroundStyle: Color = .primary
    ) -> some View {
        Button {
            send(action)
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 50, height: 50)
                .background(controlBackground, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.displayTitle)
    }

    private var unicodeHelperLabel: some View {
        Label(
            "Chinese and other Unicode text uses the optional TV input helper.",
            systemImage: "character.cursor.ibeam"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var unicodeHelperButton: some View {
        Button {
            installUnicodeInputHelper()
        } label: {
            Label("Install Input Helper", systemImage: "keyboard")
        }
        .buttonStyle(.bordered)
        .disabled(deviceOperationInProgress)
    }

}

private struct RemoteStatusView: View {
    var status: ADBTVRemoteStatus
    var cancel: () -> Void

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .sending(let action):
            sendingStatus("Sending \(action.displayTitle)")
        case .sendingText:
            sendingStatus("Sending text")
        case .sent(let action):
            Label("Sent \(action.displayTitle)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .sentText:
            Label("Text sent", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(_, let userMessage, let diagnosticDetail):
            RemoteFailureView(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        case .failedText(let userMessage, let diagnosticDetail):
            RemoteFailureView(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        }
    }

    private func sendingStatus(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(role: .cancel, action: cancel) {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct RemoteFailureView: View {
    var userMessage: String
    var diagnosticDetail: DiagnosticDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
        }
    }
}

private struct DiagnosticDisclosure: View {
    var diagnosticDetail: DiagnosticDetail

    var body: some View {
        DisclosureGroup("Technical Details") {
            ScrollView([.horizontal, .vertical]) {
                Text(diagnosticDetail.formattedDescription)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
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
        case .volumeMute:
            return "Mute"
        case .power:
            return "Power"
        case .mediaPrevious:
            return "Previous"
        case .mediaRewind:
            return "Rewind"
        case .mediaPlayPause:
            return "Play or Pause"
        case .mediaFastForward:
            return "Fast Forward"
        case .mediaNext:
            return "Next"
        case .mediaStop:
            return "Stop"
        case .enter:
            return "Enter"
        case .delete:
            return "Delete"
        case .tab:
            return "Tab"
        }
    }
}

private extension UTType {
    static var adbTVAPK: UTType {
        UTType(importedAs: "com.android.package-archive", conformingTo: .data)
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
