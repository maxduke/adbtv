import ADBClientCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct ADBTVRootView: View {
    @Environment(\.scenePhase) private var scenePhase
#if os(iOS)
    @Environment(\.openURL) private var openURL
#endif

    private let deviceStore: ADBTVDeviceStore
    private let bonjourCapability: ADBTVBonjourCapability
    private let initiallyPresentsFileBrowser: Bool

    @State private var model: ADBTVAppModel
    @State private var isFileImporterPresented = false
    @State private var isAddDevicePresented = false
    @State private var isPairDevicePresented = false
    @State private var isAboutPresented: Bool
    @State private var repairingDevice: ADBTVDeviceSummary?
    @State private var renamingDevice: ADBTVDeviceSummary?
    @State private var devicePersistenceError: DiagnosticDetail?
    @State private var installTask: Task<Void, Never>?
    @State private var remoteTask: Task<Void, Never>?
    @State private var remoteSession: ADBTVRemoteSession?
    @State private var remoteSessionDeviceID: ADBTVDeviceSummary.ID?
    @State private var remoteSessionToken: UUID?
    @State private var remoteInputTask: Task<Void, Never>?
    @State private var installedAppsTask: Task<Void, Never>?
    @State private var installedAppsOperationID: UUID?
    @State private var installedAppDetailsTask: Task<Void, Never>?
    @State private var installedAppDetailsOperationID: UUID?
    @State private var installedAppsState = ADBTVInstalledAppsViewState()
    @State private var deviceToolsTask: Task<Void, Never>?
    @State private var deviceToolsOperationID: UUID?
    @State private var deviceToolsState = ADBTVDeviceToolsViewState()
    @State private var pairingTask: Task<Void, Never>?
    @State private var deviceConnectionTask: Task<Void, Never>?
    @State private var deviceConnectionState = ADBTVSavedDeviceConnectionState.idle
    @State private var automaticDiscoveryPolicy = ADBTVAutomaticDiscoveryPolicy()
    @State private var helperReplacementDevice: ADBTVDeviceSummary?
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
        self.initiallyPresentsFileBrowser = false
        self.bonjourCapability = bonjourDiscoveryAvailable.map {
            ADBTVBonjourCapability(
                isAvailable: $0,
                automaticallyStartsDiscovery: automaticallyStartsDiscovery
            )
        } ?? .current(automaticallyStartsDiscovery: automaticallyStartsDiscovery)
        self._model = State(initialValue: initialModel)
        self._isAboutPresented = State(initialValue: initiallyPresentsAbout)
        self._repairingDevice = State(initialValue: nil)
        self._renamingDevice = State(initialValue: nil)
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
        initiallyPresentsConnectionRepair: Bool = false,
        initiallyPresentsDeviceRename: Bool = false,
        initiallyPresentsInstalledApps: Bool = false,
        initiallyPresentsDeviceTools: Bool = false,
        initiallyPresentsFileBrowser: Bool = false
    ) {
        self.deviceStore = deviceStore
        self.initiallyPresentsFileBrowser = initiallyPresentsFileBrowser
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
        self._renamingDevice = State(
            initialValue: initiallyPresentsDeviceRename ? model.devices.first : nil
        )
        if initiallyPresentsInstalledApps, let deviceID = model.devices.first?.id {
            self._installedAppsState = State(
                initialValue: .preview(deviceID: deviceID)
            )
        }
        if initiallyPresentsDeviceTools, let deviceID = model.devices.first?.id {
            self._deviceToolsState = State(
                initialValue: .preview(deviceID: deviceID)
            )
        }
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
            NavigationStack {
                if let stateDevice = deviceConnectionState.device {
                    let connectionDevice = model.devices.first(where: { $0.id == stateDevice.id })
                        ?? stateDevice
                    SavedDeviceConnectionView(
                        device: connectionDevice,
                        state: deviceConnectionState,
                        retry: { selectSavedDevice(id: connectionDevice.id) },
                        repair: { repairingDevice = connectionDevice },
                        rename: { renamingDevice = connectionDevice }
                    )
                } else if let device = model.selectedDevice, initiallyPresentsFileBrowser {
                    ADBTVFileBrowserView(device: device)
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
                        installedAppsState: installedAppsState.forDevice(device.id),
                        deviceToolsState: deviceToolsState.forDevice(device.id),
                        repair: { repairingDevice = device },
                        rename: { renamingDevice = device },
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
                        sendRepeatingRemoteAction: { action in
                            sendRemoteAction(action, to: device, policy: .onlyWhenIdle, haptic: false)
                        },
                        sendKeyboardRemoteAction: { action in
                            sendRemoteAction(action, to: device, haptic: false)
                        },
                        startRemoteSession: {
                            startRemoteSession(for: device)
                        },
                        stopRemoteSession: stopRemoteSession,
                        retryRemoteSession: retryRemoteSession,
                        sendRemoteText: {
                            sendRemoteText(to: device)
                        },
                        cancelRemoteOperation: cancelRemoteOperation,
                        installUnicodeInputHelper: {
                            installUnicodeInputHelper(on: device)
                        },
                        loadInstalledApps: { scope in
                            runInstalledAppCommand(.list(scope), on: device)
                        },
                        launchInstalledApp: { package in
                            runInstalledAppCommand(.launch(package), on: device)
                        },
                        forceStopInstalledApp: { package in
                            runInstalledAppCommand(.forceStop(package), on: device)
                        },
                        uninstallInstalledApp: { package in
                            runInstalledAppCommand(.uninstall(package), on: device)
                        },
                        cancelInstalledAppOperation: cancelInstalledAppOperation,
                        loadDeviceInformation: {
                            runDeviceTool(.information, on: device)
                        },
                        captureScreenshot: {
                            runDeviceTool(.screenshot, on: device)
                        },
                        runShellCommand: { command in
                            runDeviceTool(.shell(command: command), on: device)
                        },
                        cleanCaches: {
                            let desiredFreeByteCount = deviceToolsState.information?
                                .storage?.totalByteCount ?? 1_000_000_000_000
                            runDeviceTool(
                                .cacheCleanup(desiredFreeByteCount: desiredFreeByteCount),
                                on: device
                            )
                        },
                        cancelDeviceToolOperation: cancelDeviceToolOperation
                    )
                    .id(device.id)
                } else {
                    ContentUnavailableView("Select a Device", systemImage: "tv.and.hifispeaker.fill")
                }
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
        .sheet(item: $renamingDevice) { device in
            RenameDeviceView(device: device) { displayName in
                try renameDevice(id: device.id, to: displayName)
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
        .confirmationDialog(
            "Replace Input Helper?",
            isPresented: Binding(
                get: { helperReplacementDevice != nil },
                set: { isPresented in
                    if !isPresented {
                        helperReplacementDevice = nil
                    }
                }
            ),
            presenting: helperReplacementDevice
        ) { device in
            Button("Replace Helper", role: .destructive) {
                helperReplacementDevice = nil
                startInstall(
                    for: device,
                    isUnicodeInputHelper: true,
                    replacingUnicodeInputHelper: true
                )
            }
        } message: { _ in
            Text(
                "Android cannot update the installed helper because it was signed differently. "
                    + "Replacing it removes only the helper, then installs this version. "
                    + "No TV app data is affected."
            )
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
            stopRemoteSession()
            installedAppsTask?.cancel()
            installedAppsOperationID = nil
            installedAppDetailsTask?.cancel()
            installedAppDetailsOperationID = nil
            deviceToolsTask?.cancel()
            deviceToolsOperationID = nil
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
            stopRemoteSession()
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
            guard ADBTVInstallPackageKind(fileName: url.lastPathComponent) != nil else {
                model.failInstall(
                    userMessage: "Select an APK or APKM file.",
                    diagnosticDetail: DiagnosticDetail(
                        summary: "The selected file does not use the .apk or .apkm extension.",
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
                userMessage: "Could not open the selected app package.",
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

    private func renameDevice(
        id: ADBTVDeviceSummary.ID,
        to displayName: String
    ) throws {
        var updatedModel = model
        try updatedModel.renameDevice(id: id, to: displayName)
        try deviceStore.saveDevices(updatedModel.devices)
        model = updatedModel
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

        cancelInstalledAppDetailsLoad()
        deviceConnectionTask?.cancel()
        deviceConnectionTask = nil

        guard let id,
              let device = model.devices.first(where: { $0.id == id }) else {
            deviceConnectionState = .idle
            _ = model.selectDevice(id: nil)
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

    private func startInstall(
        for device: ADBTVDeviceSummary,
        isUnicodeInputHelper: Bool = false,
        replacingUnicodeInputHelper: Bool = false
    ) {
        let installModel = model
        guard model.startInstall(on: device.id) else {
            return
        }

        installTask?.cancel()
        installTask = Task {
            let completion: InstallCompletion
            do {
                if replacingUnicodeInputHelper {
                    try await Self.uninstallUnicodeInputHelper(from: device)
                }
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
                    userMessage: replacingUnicodeInputHelper
                        ? "Could not replace the Input Helper."
                        : Self.installUserMessage(for: error),
                    diagnosticDetail: Self.installDiagnosticDetail(
                        error,
                        device: device,
                        operation: replacingUnicodeInputHelper
                            ? "replaceUnicodeInputHelper" : "installAPK"
                    )
                )
            }

            await MainActor.run {
                completeInstall(
                    completion,
                    on: device.id,
                    isUnicodeInputHelper: isUnicodeInputHelper,
                    replacingUnicodeInputHelper: replacingUnicodeInputHelper
                )
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
        startInstall(for: device, isUnicodeInputHelper: true)
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
    ) async throws -> ADBTVInstallReport {
#if canImport(Network) && canImport(Security)
        let cleanupRecorder = ADBTVInstallCleanupRecorder()
        do {
            return try await ADBTVOperationTimeoutPolicy.apkInstallation.run(operation: .apkInstallation) {
                let operation = ADBTVInstallOperation()
                let package = try await operation.prepareSelectedPackage(
                    from: installModel,
                    eventHandler: eventHandler
                )
                defer { try? package.removeTemporaryFiles() }
                await cleanupRecorder.record(plan: package.singleAPKPlan)
                var connection = try await connectedDevice(for: device)
                defer { connection.cancel() }
                do {
                    return try await operation.installPreparedPackage(
                        package,
                        using: &connection,
                        eventHandler: eventHandler
                    )
                } catch let error as ADBPackageSessionInstallCancellationError {
                    let cleanupError = await retryPackageSessionCleanupIfNeeded(
                        error: error,
                        device: device
                    )
                    await cleanupRecorder.record(packageSessionCleanupError: cleanupError)
                    throw ADBTVInstallCancellationError(cleanupError: cleanupError)
                } catch let error as ADBPackageSessionInstallError {
                    let recoveredError = await retryPackageSessionCleanupIfNeeded(
                        error: error,
                        device: device
                    )
                    throw recoveredError
                }
            }
        } catch {
            if let cancellationError = error as? ADBTVInstallCancellationError {
                throw cancellationError
            }
            let preparedPlan = await cleanupRecorder.recordedPlan()
            let packageSessionCleanupError = await cleanupRecorder
                .recordedPackageSessionCleanupError()
            if Task.isCancelled {
                var cleanupError = packageSessionCleanupError
                if cleanupError == nil, let preparedPlan {
                    cleanupError = await cleanupStagedPackageAfterInterruption(
                        plan: preparedPlan,
                        device: device
                    )
                }
                throw ADBTVInstallCancellationError(cleanupError: cleanupError)
            }
            if let timeoutError = error as? ADBTVOperationTimeoutError {
                var cleanupError = packageSessionCleanupError
                if cleanupError == nil, let preparedPlan {
                    cleanupError = await cleanupStagedPackageAfterInterruption(
                        plan: preparedPlan,
                        device: device
                    )
                }
                if let cleanupError {
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

    private static func uninstallUnicodeInputHelper(
        from device: ADBTVDeviceSummary
    ) async throws {
#if canImport(Network) && canImport(Security)
        try await ADBTVOperationTimeoutPolicy.installedApps.run(operation: .installedApps) {
            var connection = try await connectedDevice(for: device)
            defer { connection.cancel() }
            let package = try ADBTVInstalledPackage(
                packageName: ADBTVUnicodeInputHelper.packageName
            )
            try await ADBTVInstalledAppManager().uninstall(package, using: &connection)
        }
#else
        throw ADBTVInstallOperationError.unsupportedPlatform
#endif
    }

    @MainActor
    private func completeInstall(
        _ completion: InstallCompletion,
        on deviceID: ADBTVDeviceSummary.ID,
        isUnicodeInputHelper: Bool,
        replacingUnicodeInputHelper: Bool
    ) {
        installTask = nil
        switch completion {
        case .success(let report):
            model.finishInstall(result: report.result, on: deviceID)
            if isUnicodeInputHelper,
               !replacingUnicodeInputHelper,
               report.result.isUpdateIncompatible {
                helperReplacementDevice = model.devices.first { $0.id == deviceID }
            }
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

    private static func retryPackageSessionCleanupIfNeeded(
        error: ADBPackageSessionInstallCancellationError,
        device: ADBTVDeviceSummary
    ) async -> String? {
        guard let sessionID = error.sessionID, error.abandonError != nil else {
            return error.abandonError
        }
        return await cleanupPackageSessionAfterInterruption(id: sessionID, device: device)
    }

    private static func retryPackageSessionCleanupIfNeeded(
        error: ADBPackageSessionInstallError,
        device: ADBTVDeviceSummary
    ) async -> ADBPackageSessionInstallError {
        guard case let .operationFailed(sessionID, underlyingError, abandonError) = error,
              let sessionID,
              abandonError != nil else {
            return error
        }
        let cleanupError = await cleanupPackageSessionAfterInterruption(
            id: sessionID,
            device: device
        )
        return .operationFailed(
            sessionID: cleanupError == nil ? nil : sessionID,
            underlyingError: underlyingError,
            abandonError: cleanupError
        )
    }

    private static func cleanupPackageSessionAfterInterruption(
        id: Int,
        device: ADBTVDeviceSummary
    ) async -> String? {
        await Task.detached { () -> String? in
            do {
                return try await ADBTVOperationTimeoutPolicy.packageSessionCleanup.run(
                    operation: .packageSessionCleanup
                ) {
                    var connection = try await connectedDevice(for: device)
                    defer { connection.cancel() }
                    return await ADBPackageSessionInstaller().abandon(
                        id: id,
                        using: &connection
                    )
                }
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

    private static func installDiagnosticDetail(
        _ error: Error,
        device: ADBTVDeviceSummary,
        operation: String = "installAPK"
    ) -> DiagnosticDetail {
        var context = [
            "device": device.connectionDescription,
            "operation": operation
        ]
        if error is ADBAPKValidationError
            || error is ADBTVInstallFileError
            || error is ADBTVAPKMExtractionError {
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
            return "App installation timed out."
        }
        if error is ADBAPKValidationError {
            return "The selected file is not a valid APK."
        }
        if error is ADBTVAPKMExtractionError {
            return "The selected file is not a valid APKM bundle."
        }
        if error is ADBTVInstallFileError {
            return "Could not read the selected app package."
        }
        if error is ADBTVInstallDownloadError {
            return "Could not download the app package."
        }

        return "Could not install the app package."
    }

    private func startRemoteSession(for device: ADBTVDeviceSummary) {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-preview") else {
            return
        }
        guard scenePhase == .active,
              remoteSessionDeviceID != device.id || remoteSession == nil else {
            return
        }

        stopRemoteSession()
        let token = UUID()
        let session = ADBTVRemoteSession(
            channelFactory: {
#if canImport(Network) && canImport(Security)
                let connection = try await Self.connectedDevice(for: device)
                return ADBTVRemoteConnectionChannel(connection: connection)
#else
                throw ADBTVRemoteOperationError.unsupportedPlatform
#endif
            },
            eventHandler: { event in
                await MainActor.run {
                    handleRemoteSessionEvent(event, for: device, token: token)
                }
            }
        )
        remoteSession = session
        remoteSessionDeviceID = device.id
        remoteSessionToken = token
        model.remoteStatus = .connecting
        Task { await session.start() }
    }

    private func stopRemoteSession() {
        guard let session = remoteSession else {
            return
        }
        remoteSession = nil
        remoteSessionDeviceID = nil
        remoteSessionToken = nil
        remoteInputTask?.cancel()
        remoteInputTask = nil
        if model.activeDeviceOperation == nil {
            model.remoteStatus = .idle
        }
        Task { await session.close() }
    }

    private func retryRemoteSession() {
        guard let remoteSession else {
            return
        }
        model.remoteStatus = .connecting
        Task { await remoteSession.retryConnection() }
    }

    private func sendRemoteAction(
        _ action: ADBTVRemoteAction,
        to device: ADBTVDeviceSummary,
        policy: ADBTVRemoteSession.EnqueuePolicy = .ordered,
        haptic: Bool = true
    ) {
        guard remoteSessionDeviceID == device.id,
              let remoteSession,
              let token = remoteSessionToken else {
            return
        }
        let previousInputTask = remoteInputTask
        remoteInputTask = Task {
            await previousInputTask?.value
            guard !Task.isCancelled else {
                return
            }
            let result = await remoteSession.enqueue(action, policy: policy)
            await MainActor.run {
                guard remoteSessionToken == token, remoteSessionDeviceID == device.id else {
                    return
                }
                switch result {
                case .accepted:
                    if haptic {
                        Self.remoteImpactFeedback()
                    }
                case .full:
                    model.remoteStatus = .catchingUp
                    Self.remoteWarningFeedback()
                case .busy, .unavailable:
                    break
                }
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
        case .install, .installedApps, .deviceTools:
            return
        }
    }

    private func runInstalledAppCommand(
        _ command: ADBTVInstalledAppCommand,
        on device: ADBTVDeviceSummary
    ) {
        guard model.startInstalledAppOperation(on: device.id) else {
            return
        }

        if installedAppsState.deviceID != device.id {
            installedAppsState = ADBTVInstalledAppsViewState(deviceID: device.id)
        }
        if case .list(let scope) = command {
            cancelInstalledAppDetailsLoad()
            if installedAppsState.scope != scope {
                installedAppsState.packages = []
            }
            installedAppsState.scope = scope
            installedAppsState.details = [:]
        }
        installedAppsState.status = command.inProgressStatus
        let operationID = UUID()
        installedAppsOperationID = operationID

        installedAppsTask = Task {
            let completion: ADBTVInstalledAppCompletion
            do {
                completion = .success(try await Self.performInstalledAppCommand(
                    command,
                    on: device
                ))
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                completion = .failure(
                    userMessage: command.failureMessage,
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: Self.operationDiagnosticContext(
                            error: error,
                            base: [
                                "device": device.connectionDescription,
                                "operation": command.operationName,
                                "package": command.packageName ?? ""
                            ]
                        )
                    )
                )
            }

            await MainActor.run {
                completeInstalledAppCommand(
                    completion,
                    operationID: operationID,
                    on: device
                )
            }
        }
    }

    private func cancelInstalledAppOperation() {
        guard case .installedApps(let deviceID) = model.activeDeviceOperation else {
            return
        }
        installedAppsTask?.cancel()
        installedAppsTask = nil
        installedAppsOperationID = nil
        guard model.cancelInstalledAppOperation(on: deviceID),
              installedAppsState.deviceID == deviceID else {
            return
        }
        installedAppsState.status = .ready(message: "Cancelled.")
    }

    private func completeInstalledAppCommand(
        _ completion: ADBTVInstalledAppCompletion,
        operationID: UUID,
        on device: ADBTVDeviceSummary
    ) {
        guard installedAppsOperationID == operationID,
              installedAppsState.deviceID == device.id,
              model.finishInstalledAppOperation(on: device.id) else {
            return
        }
        installedAppsTask = nil
        installedAppsOperationID = nil

        switch completion {
        case .success(.listed(let packages)):
            installedAppsState.packages = packages
            installedAppsState.status = .ready(message: nil)
            startInstalledAppDetailsLoad(packages, on: device)
        case .success(.launched(let package)):
            installedAppsState.details[package.packageName]?.isStopped = false
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.status = .ready(
                message: "Launched \(name)."
            )
        case .success(.stopped(let package)):
            if installedAppsState.details[package.packageName] == nil {
                installedAppsState.details[package.packageName] = ADBTVInstalledAppDetails(
                    isStopped: true
                )
            } else {
                installedAppsState.details[package.packageName]?.isStopped = true
            }
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.status = .ready(message: "Stopped \(name).")
        case .success(.uninstalled(let package)):
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.packages.removeAll { $0 == package }
            installedAppsState.details.removeValue(forKey: package.packageName)
            installedAppsState.status = .ready(
                message: "Uninstalled \(name)."
            )
        case .failure(let userMessage, let diagnosticDetail):
            installedAppsState.status = .failed(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        }
    }

    private func runDeviceTool(
        _ operation: ADBTVDeviceToolOperation,
        on device: ADBTVDeviceSummary
    ) {
        guard model.startDeviceToolsOperation(on: device.id) else {
            return
        }

        if deviceToolsState.deviceID != device.id {
            deviceToolsState = ADBTVDeviceToolsViewState(deviceID: device.id)
        }
        deviceToolsState.start(operation)
        let operationID = UUID()
        deviceToolsOperationID = operationID

        deviceToolsTask = Task {
            let completion: ADBTVDeviceToolCompletion
            do {
                completion = .success(
                    try await Self.performDeviceTool(operation, on: device)
                )
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                completion = .failure(
                    operation: operation,
                    userMessage: Self.deviceToolUserMessage(for: operation, error: error),
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: Self.deviceToolDiagnosticContext(
                            error: error,
                            base: [
                                "device": device.connectionDescription,
                                "operation": operation.operationName
                            ]
                        )
                    )
                )
            }

            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                completeDeviceTool(
                    completion,
                    operationID: operationID,
                    on: device
                )
            }
        }
    }

    private func cancelDeviceToolOperation() {
        guard case .deviceTools(let deviceID) = model.activeDeviceOperation else {
            return
        }
        deviceToolsTask?.cancel()
        deviceToolsTask = nil
        deviceToolsOperationID = nil
        guard model.cancelDeviceToolsOperation(on: deviceID),
              deviceToolsState.deviceID == deviceID else {
            return
        }
        deviceToolsState.cancel()
    }

    private func completeDeviceTool(
        _ completion: ADBTVDeviceToolCompletion,
        operationID: UUID,
        on device: ADBTVDeviceSummary
    ) {
        guard deviceToolsOperationID == operationID,
              deviceToolsState.deviceID == device.id,
              model.finishDeviceToolsOperation(on: device.id) else {
            return
        }
        deviceToolsTask = nil
        deviceToolsOperationID = nil

        switch completion {
        case .success(let result):
            deviceToolsState.finish(result)
        case .failure(let operation, let userMessage, let diagnosticDetail):
            deviceToolsState.fail(
                operation,
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        }
    }

    private func startInstalledAppDetailsLoad(
        _ packages: [ADBTVInstalledPackage],
        on device: ADBTVDeviceSummary
    ) {
        cancelInstalledAppDetailsLoad()
        guard !packages.isEmpty else {
            return
        }

        let operationID = UUID()
        installedAppDetailsOperationID = operationID
        installedAppDetailsTask = Task {
            let details = await Self.loadInstalledAppDetails(packages, on: device)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard installedAppDetailsOperationID == operationID,
                      installedAppsState.deviceID == device.id else {
                    return
                }
                let currentPackages = Set(installedAppsState.packages.map(\.packageName))
                installedAppsState.details = details.filter {
                    currentPackages.contains($0.key)
                }
                installedAppDetailsTask = nil
                installedAppDetailsOperationID = nil
            }
        }
    }

    private func cancelInstalledAppDetailsLoad() {
        installedAppDetailsTask?.cancel()
        installedAppDetailsTask = nil
        installedAppDetailsOperationID = nil
    }

    private static func loadInstalledAppDetails(
        _ packages: [ADBTVInstalledPackage],
        on device: ADBTVDeviceSummary
    ) async -> [String: ADBTVInstalledAppDetails] {
#if canImport(Network) && canImport(Security)
        do {
            return try await ADBTVOperationTimeoutPolicy.installedApps.run(
                operation: .installedApps
            ) {
                var connection = try await connectedDevice(for: device)
                defer { connection.cancel() }
                return await ADBTVInstalledAppManager().details(
                    for: packages,
                    using: &connection
                )
            }
        } catch {
            return [:]
        }
#else
        return [:]
#endif
    }

    private static func performInstalledAppCommand(
        _ command: ADBTVInstalledAppCommand,
        on device: ADBTVDeviceSummary
    ) async throws -> ADBTVInstalledAppResult {
#if canImport(Network) && canImport(Security)
        return try await ADBTVOperationTimeoutPolicy.installedApps.run(
            operation: .installedApps
        ) {
            var connection = try await connectedDevice(for: device)
            defer { connection.cancel() }
            let manager = ADBTVInstalledAppManager()

            switch command {
            case .list(let scope):
                return .listed(try await manager.list(scope: scope, using: &connection))
            case .launch(let package):
                try await manager.launch(package, using: &connection)
                return .launched(package)
            case .forceStop(let package):
                try await manager.forceStop(package, using: &connection)
                return .stopped(package)
            case .uninstall(let package):
                try await manager.uninstall(package, using: &connection)
                return .uninstalled(package)
            }
        }
#else
        throw ADBTVInstalledAppOperationError.unsupportedPlatform
#endif
    }

    private static func performDeviceTool(
        _ operation: ADBTVDeviceToolOperation,
        on device: ADBTVDeviceSummary
    ) async throws -> ADBTVDeviceToolResult {
#if canImport(Network) && canImport(Security)
        let work: @Sendable () async throws -> ADBTVDeviceToolResult = {
            let connection = try await connectedDevice(for: device)
            defer { connection.cancel() }
            var tools = ADBTVDeviceTools(session: connection)

            switch operation {
            case .information:
                return .information(try await tools.loadInformation(systemIdentity: "host::adbtv"))
            case .cacheCleanup(let desiredFreeByteCount):
                try await tools.trimCaches(desiredFreeByteCount: desiredFreeByteCount)
                return .cacheCleanup(
                    try await tools.loadInformation(systemIdentity: "host::adbtv")
                )
            case .screenshot:
                return .screenshot(try await tools.captureScreenshot())
            case .shell(let command):
                return .shell(try await tools.runShellCommand(command))
            }
        }

        switch operation {
        case .information:
            return try await ADBTVOperationTimeoutPolicy.deviceInformation.run(
                operation: .deviceInformation,
                work
            )
        case .cacheCleanup:
            return try await ADBTVOperationTimeoutPolicy.cacheCleanup.run(
                operation: .cacheCleanup,
                work
            )
        case .screenshot:
            return try await ADBTVOperationTimeoutPolicy.screenshot.run(
                operation: .screenshot,
                work
            )
        case .shell:
            return try await ADBTVOperationTimeoutPolicy.shellCommand.run(
                operation: .shellCommand,
                work
            )
        }
#else
        throw ADBTVDeviceToolOperationError.unsupportedPlatform
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
        case .textSuccess:
            model.finishRemoteText(on: deviceID)
        case .textFailure(let userMessage, let diagnosticDetail):
            model.failRemoteText(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail,
                on: deviceID
            )
        }
    }

    @MainActor
    private func handleRemoteSessionEvent(
        _ event: ADBTVRemoteSessionEvent,
        for device: ADBTVDeviceSummary,
        token: UUID
    ) {
        guard remoteSessionToken == token, remoteSessionDeviceID == device.id else {
            return
        }

        switch event {
        case .connecting:
            model.remoteStatus = .connecting
        case .ready:
            model.remoteStatus = .idle
        case .sending, .sent:
            break
        case .drained:
            if model.remoteStatus == .catchingUp {
                model.remoteStatus = .idle
            }
        case .actionFailed:
            Self.remoteWarningFeedback()
        case .reconnecting:
            model.remoteStatus = .reconnecting
        case .connectionFailed(let failure):
            model.remoteStatus = .connectionFailed(
                userMessage: failure.timedOut
                    ? "The TV did not respond in time."
                    : "Could not connect to the TV.",
                diagnosticDetail: Self.remoteSessionDiagnosticDetail(failure, device: device)
            )
            Self.remoteWarningFeedback()
        case .reconnectFailed(let actionFailure, let connectionFailure):
            var detail = Self.remoteSessionDiagnosticDetail(connectionFailure, device: device)
            detail.context["failedAction"] = actionFailure.action?.displayTitle ?? "unknown"
            detail.context["actionFailure"] = actionFailure.summary
            model.remoteStatus = .connectionFailed(
                userMessage: "Connection to the TV was lost.",
                diagnosticDetail: detail
            )
            Self.remoteWarningFeedback()
        case .closed:
            break
        }
    }

    private static func remoteSessionDiagnosticDetail(
        _ failure: ADBTVRemoteSessionFailure,
        device: ADBTVDeviceSummary
    ) -> DiagnosticDetail {
        var context = [
            "device": device.connectionDescription,
            "operation": "remoteSession",
            "stage": failure.stage.rawValue
        ]
        if let action = failure.action {
            context["action"] = action.displayTitle
        }
        return DiagnosticDetail(summary: failure.summary, context: context)
    }

    private static func remoteImpactFeedback() {
#if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
    }

    private static func remoteWarningFeedback() {
#if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
#endif
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

    private static func deviceToolUserMessage(
        for operation: ADBTVDeviceToolOperation,
        error: Error
    ) -> String {
        if case .screenshot = operation,
           let toolsError = error as? ADBTVDeviceToolsError,
           case .screenshotUnavailable = toolsError {
            return "Screenshot unavailable. The current app or TV may block screen capture."
        }
        return operation.failureMessage
    }

    private static func deviceToolDiagnosticContext(
        error: Error,
        base: [String: String]
    ) -> [String: String] {
        var context = operationDiagnosticContext(error: error, base: base)
        if let toolsError = error as? ADBTVDeviceToolsError,
           case let .screenshotUnavailable(byteCount, message) = toolsError {
            context["outputByteCount"] = String(byteCount)
            if let message {
                context["deviceMessage"] = message
            }
        }
        return context
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
    case success(ADBTVInstallReport)
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

private actor ADBTVInstallCleanupRecorder {
    private var plan: ADBAPKInstallPlan?
    private var packageSessionCleanupError: String?

    func record(plan: ADBAPKInstallPlan?) {
        self.plan = plan
    }

    func record(packageSessionCleanupError: String?) {
        self.packageSessionCleanupError = packageSessionCleanupError
    }

    func recordedPlan() -> ADBAPKInstallPlan? {
        plan
    }

    func recordedPackageSessionCleanupError() -> String? {
        packageSessionCleanupError
    }
}

private enum RemoteCompletion: Sendable {
    case textSuccess
    case textFailure(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

private enum ADBTVInstalledAppCommand: Sendable {
    case list(ADBTVInstalledAppScope)
    case launch(ADBTVInstalledPackage)
    case forceStop(ADBTVInstalledPackage)
    case uninstall(ADBTVInstalledPackage)

    var inProgressStatus: ADBTVInstalledAppsStatus {
        switch self {
        case .list:
            return .loading
        case .launch(let package):
            return .launching(package)
        case .forceStop(let package):
            return .stopping(package)
        case .uninstall(let package):
            return .uninstalling(package)
        }
    }

    var operationName: String {
        switch self {
        case .list(let scope):
            return scope == .user ? "listUserApps" : "listSystemApps"
        case .launch:
            return "launchInstalledApp"
        case .forceStop:
            return "forceStopInstalledApp"
        case .uninstall:
            return "uninstallInstalledApp"
        }
    }

    var packageName: String? {
        switch self {
        case .list:
            return nil
        case .launch(let package), .forceStop(let package), .uninstall(let package):
            return package.packageName
        }
    }

    var failureMessage: String {
        switch self {
        case .list:
            return "Could not load installed apps."
        case .launch:
            return "Could not launch this app."
        case .forceStop:
            return "Could not stop this app."
        case .uninstall:
            return "Could not uninstall this app."
        }
    }
}

private enum ADBTVInstalledAppResult: Sendable {
    case listed([ADBTVInstalledPackage])
    case launched(ADBTVInstalledPackage)
    case stopped(ADBTVInstalledPackage)
    case uninstalled(ADBTVInstalledPackage)
}

private enum ADBTVInstalledAppCompletion: Sendable {
    case success(ADBTVInstalledAppResult)
    case failure(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

private enum ADBTVDeviceToolCompletion: Sendable {
    case success(ADBTVDeviceToolResult)
    case failure(
        operation: ADBTVDeviceToolOperation,
        userMessage: String,
        diagnosticDetail: DiagnosticDetail
    )
}

private enum ADBTVDeviceToolOperationError: Error {
    case unsupportedPlatform
}

private struct ADBTVInstalledAppsViewState: Equatable {
    var deviceID: ADBTVDeviceSummary.ID?
    var scope: ADBTVInstalledAppScope
    var packages: [ADBTVInstalledPackage]
    var details: [String: ADBTVInstalledAppDetails]
    var status: ADBTVInstalledAppsStatus

    init(
        deviceID: ADBTVDeviceSummary.ID? = nil,
        scope: ADBTVInstalledAppScope = .user,
        packages: [ADBTVInstalledPackage] = [],
        details: [String: ADBTVInstalledAppDetails] = [:],
        status: ADBTVInstalledAppsStatus = .idle
    ) {
        self.deviceID = deviceID
        self.scope = scope
        self.packages = packages
        self.details = details
        self.status = status
    }

    func forDevice(_ deviceID: ADBTVDeviceSummary.ID) -> Self {
        self.deviceID == deviceID ? self : Self(deviceID: deviceID)
    }

    static func preview(deviceID: ADBTVDeviceSummary.ID) -> Self {
        let packageNames = [
            "com.disney.disneyplus",
            "com.google.android.youtube.tv",
            "com.netflix.ninja",
            "com.example.very.long.android.television.streaming.application"
        ]
        return Self(
            deviceID: deviceID,
            packages: packageNames.compactMap { try? ADBTVInstalledPackage(packageName: $0) },
            details: [
                packageNames[0]: ADBTVInstalledAppDetails(
                    displayName: "Disney+",
                    versionName: "4.18.0",
                    versionCode: 418_000,
                    firstInstallTimeMilliseconds: 1_704_067_200_000,
                    lastUpdateTimeMilliseconds: 1_719_792_000_000,
                    apkByteCount: 38_797_312
                ),
                packageNames[1]: ADBTVInstalledAppDetails(displayName: "YouTube"),
                packageNames[2]: ADBTVInstalledAppDetails(displayName: "Netflix"),
                packageNames[3]: ADBTVInstalledAppDetails(
                    displayName: "A Streaming App With a Longer Name"
                )
            ],
            status: .ready(message: nil)
        )
    }
}

private enum ADBTVInstalledAppsStatus: Equatable {
    case idle
    case loading
    case ready(message: String?)
    case launching(ADBTVInstalledPackage)
    case stopping(ADBTVInstalledPackage)
    case uninstalling(ADBTVInstalledPackage)
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)

    var isBusy: Bool {
        switch self {
        case .loading, .launching, .stopping, .uninstalling:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }
}

private enum ADBTVInstalledAppOperationError: Error {
    case unsupportedPlatform
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
    var rename: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeviceHeader(
                    device: device,
                    repair: repair,
                    rename: rename,
                    actionsDisabled: state.isConnecting
                )

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

private struct RenameDeviceView: View {
    @Environment(\.dismiss) private var dismiss

    let device: ADBTVDeviceSummary
    let saveName: (String) throws -> Void

    @State private var displayName: String
    @State private var saveError: DiagnosticDetail?

    init(
        device: ADBTVDeviceSummary,
        saveName: @escaping (String) throws -> Void
    ) {
        self.device = device
        self.saveName = saveName
        self._displayName = State(initialValue: device.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device Name") {
                    TextField("Name", text: $displayName)
                }

                if let saveError {
                    Section {
                        Label("Could not rename this device.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        DiagnosticDisclosure(diagnosticDetail: saveError)
                    }
                }
            }
            .navigationTitle("Rename Device")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            normalizedDisplayName.isEmpty
                                || normalizedDisplayName == device.displayName
                        )
                }
            }
        }
        .onChange(of: displayName) { _, _ in saveError = nil }
    }

    private var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        do {
            try saveName(normalizedDisplayName)
            dismiss()
        } catch {
            saveError = DiagnosticDetail(
                summary: String(describing: error),
                context: ["operation": "renameDevice"]
            )
        }
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
    var installedAppsState: ADBTVInstalledAppsViewState
    var deviceToolsState: ADBTVDeviceToolsViewState
    var repair: () -> Void
    var rename: () -> Void
    var chooseAPK: () -> Void
    var install: () -> Void
    var cancelInstall: () -> Void
    var sendRemoteAction: (ADBTVRemoteAction) -> Void
    var sendRepeatingRemoteAction: (ADBTVRemoteAction) -> Void
    var sendKeyboardRemoteAction: (ADBTVRemoteAction) -> Void
    var startRemoteSession: () -> Void
    var stopRemoteSession: () -> Void
    var retryRemoteSession: () -> Void
    var sendRemoteText: () -> Void
    var cancelRemoteOperation: () -> Void
    var installUnicodeInputHelper: () -> Void
    var loadInstalledApps: (ADBTVInstalledAppScope) -> Void
    var launchInstalledApp: (ADBTVInstalledPackage) -> Void
    var forceStopInstalledApp: (ADBTVInstalledPackage) -> Void
    var uninstallInstalledApp: (ADBTVInstalledPackage) -> Void
    var cancelInstalledAppOperation: () -> Void
    var loadDeviceInformation: () -> Void
    var captureScreenshot: () -> Void
    var runShellCommand: (String) -> Void
    var cleanCaches: () -> Void
    var cancelDeviceToolOperation: () -> Void

    @State private var selectedTool = ProcessInfo.processInfo.arguments.contains("--ui-install")
        || ProcessInfo.processInfo.arguments.contains("--ui-apps")
        ? DeviceTool.apps
        : ProcessInfo.processInfo.arguments.contains("--ui-tools")
            ? DeviceTool.tools
            : DeviceTool.remote
    @State private var isInstallerPresented = ProcessInfo.processInfo.arguments.contains("--ui-install")
    @State private var isFileBrowserPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeviceHeader(
                    device: device,
                    repair: repair,
                    rename: rename,
                    actionsDisabled: deviceOperationInProgress
                )

                Picker("Device Tool", selection: $selectedTool) {
                    ForEach(DeviceTool.allCases) { tool in
                        Text(tool.title).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(deviceOperationInProgress)

                switch selectedTool {
                case .remote:
                    remotePanel
                case .apps:
                    appsPanel
                case .tools:
                    deviceToolsPanel
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding()
        }
        .navigationTitle(device.displayName)
        .navigationDestination(isPresented: $isFileBrowserPresented) {
            ADBTVFileBrowserView(device: device)
        }
        .navigationDestination(isPresented: $isInstallerPresented) {
            installerView
        }
#if os(iOS)
        .navigationBarBackButtonHidden(deviceOperationInProgress)
        .navigationBarBackButtonDisplayMode(.minimal)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var remotePanel: some View {
        RemoteActionsPanel(
            status: remoteStatus,
            text: remoteTextString,
            canSendText: canSendRemoteText,
            deviceOperationInProgress: deviceOperationInProgress,
            unicodeHelperInstallStatus: unicodeHelperInstallStatus,
            send: sendRemoteAction,
            sendRepeat: sendRepeatingRemoteAction,
            sendFromKeyboard: sendKeyboardRemoteAction,
            sendText: sendRemoteText,
            startSession: startRemoteSession,
            stopSession: stopRemoteSession,
            retrySession: retryRemoteSession,
            cancelRemoteOperation: cancelRemoteOperation,
            installUnicodeInputHelper: installUnicodeInputHelper
        )
    }

    private var appsPanel: some View {
        InstalledAppsPanel(
            state: installedAppsState,
            deviceOperationInProgress: deviceOperationInProgress,
            showInstaller: { isInstallerPresented = true },
            load: loadInstalledApps,
            installHelper: {
                isInstallerPresented = true
                installUnicodeInputHelper()
            },
            launch: launchInstalledApp,
            forceStop: forceStopInstalledApp,
            uninstall: uninstallInstalledApp,
            cancel: cancelInstalledAppOperation
        )
        .onChange(of: installDraft.status) { _, status in
            if status == .succeeded {
                loadInstalledApps(.user)
            }
        }
    }

    private var installerView: some View {
        ScrollView {
            APKInstallPanel(
                installDraft: installDraft,
                installURLString: installURLString,
                canInstall: canInstall,
                deviceOperationInProgress: deviceOperationInProgress,
                chooseAPK: chooseAPK,
                install: install,
                cancelInstall: cancelInstall
            )
            .frame(maxWidth: 520, alignment: .leading)
            .padding()
        }
        .navigationTitle("Install App")
#if os(iOS)
        .navigationBarBackButtonHidden(installDraft.status.isRunning)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var deviceToolsPanel: some View {
        ADBTVDeviceToolsPanel(
            state: deviceToolsState,
            deviceOperationInProgress: deviceOperationInProgress,
            loadInformation: loadDeviceInformation,
            captureScreenshot: captureScreenshot,
            runShellCommand: runShellCommand,
            openFiles: { isFileBrowserPresented = true },
            cleanCaches: cleanCaches,
            cancel: cancelDeviceToolOperation
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
    case apps
    case tools

    var id: Self { self }

    var title: String {
        switch self {
        case .remote:
            return "Remote"
        case .apps:
            return "Apps"
        case .tools:
            return "Tools"
        }
    }

}

private extension ADBTVInstalledAppScope {
    var displayTitle: String {
        self == .user ? "User Apps" : "System Apps"
    }

    var emptyTitle: String {
        self == .user ? "No User Apps" : "No System Apps"
    }
}

private struct InstalledAppsPanel: View {
    var state: ADBTVInstalledAppsViewState
    var deviceOperationInProgress: Bool
    var showInstaller: () -> Void
    var load: (ADBTVInstalledAppScope) -> Void
    var installHelper: () -> Void
    var launch: (ADBTVInstalledPackage) -> Void
    var forceStop: (ADBTVInstalledPackage) -> Void
    var uninstall: (ADBTVInstalledPackage) -> Void
    var cancel: () -> Void

    @State private var searchText = ""
    @State private var pendingForceStop: ADBTVInstalledPackage?
    @State private var pendingUninstall: ADBTVInstalledPackage?
    @State private var selectedPackage: ADBTVInstalledPackage? =
        ProcessInfo.processInfo.arguments.contains("--ui-app-details")
            ? (try? ADBTVInstalledPackage(packageName: "com.netflix.ninja"))
            : nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Installed Apps")
                    .font(.title2.bold())
                Spacer()
                Menu {
                    Button(action: showInstaller) {
                        Label("Install Package", systemImage: "square.and.arrow.down")
                    }
                    Button(action: installHelper) {
                        Label("Install Android Helper", systemImage: "arrow.down.app")
                    }
                } label: {
                    Label("Add App", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(deviceOperationInProgress || state.status.isBusy)
                .help("Add App")
                Button { load(state.scope) } label: {
                    Label("Refresh Apps", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(deviceOperationInProgress || state.status.isBusy)
                .help("Refresh Apps")
            }

            Picker("App Type", selection: Binding(
                get: { state.scope },
                set: load
            )) {
                ForEach(ADBTVInstalledAppScope.allCases, id: \.self) { scope in
                    Text(scope.displayTitle).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .disabled(deviceOperationInProgress || state.status.isBusy)

            TextField("Search apps or packages", text: $searchText)
                .autocorrectionDisabled()

            statusContent

            if !filteredPackages.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPackages) { package in
                        installedAppRow(
                            package,
                            details: state.details[package.packageName]
                        )
                        Divider()
                    }
                }
            } else if !state.status.isBusy {
                ContentUnavailableView(
                    searchText.isEmpty ? state.scope.emptyTitle : "No Matching Apps",
                    systemImage: searchText.isEmpty ? "square.grid.2x2" : "magnifyingglass"
                )
            }
        }
        .onAppear {
            if state.status == .idle {
                load(state.scope)
            }
        }
        .onChange(of: state.scope) { _, _ in
            searchText = ""
            pendingForceStop = nil
            pendingUninstall = nil
            selectedPackage = nil
        }
        .confirmationDialog(
            "Force Stop App?",
            isPresented: Binding(
                get: { pendingForceStop != nil },
                set: { if !$0 { pendingForceStop = nil } }
            ),
            presenting: pendingForceStop
        ) { package in
            Button("Force Stop \(appTitle(for: package))", role: .destructive) {
                forceStop(package)
                pendingForceStop = nil
            }
        } message: { _ in
            Text("This stops the app, background activity, and playback without removing its data.")
        }
        .confirmationDialog(
            "Uninstall app?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            presenting: pendingUninstall
        ) { package in
            Button("Uninstall \(package.packageName)", role: .destructive) {
                uninstall(package)
                pendingUninstall = nil
            }
        } message: { package in
            Text("This removes \(package.packageName) and its app data from the TV.")
        }
        .sheet(item: $selectedPackage) { package in
            InstalledAppDetailsView(
                package: package,
                details: state.details[package.packageName],
                actionsDisabled: deviceOperationInProgress || state.status.isBusy,
                allowsUninstall: state.scope == .user,
                launch: launch,
                forceStop: forceStop,
                uninstall: uninstall
            )
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state.status {
        case .idle:
            EmptyView()
        case .loading:
            progressLabel("Loading installed apps", cancel: cancel)
        case .launching(let package):
            progressLabel("Launching \(appTitle(for: package))", cancel: cancel)
        case .stopping(let package):
            progressLabel("Stopping \(appTitle(for: package))", cancel: cancel)
        case .uninstalling(let package):
            progressLabel("Uninstalling \(appTitle(for: package))", cancel: cancel)
        case .ready(let message):
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 8) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        }
    }

    private func progressLabel(_ title: String, cancel: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: cancel) {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
        }
    }

    private func installedAppRow(
        _ package: ADBTVInstalledPackage,
        details: ADBTVInstalledAppDetails?
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedPackage = package
            } label: {
                HStack(spacing: 12) {
                    InstalledAppIconView(icon: details?.icon)

                    VStack(alignment: .leading, spacing: 2) {
                        if let displayName = details?.displayName {
                            Text(displayName)
                                .font(.headline)
                                .lineLimit(2)
                            Text(package.packageName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(package.packageName)
                                .font(.subheadline.monospaced())
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show details for \(package.packageName)")

            Menu {
                Button {
                    selectedPackage = package
                } label: {
                    Label("Details", systemImage: "info.circle")
                }

                Button {
                    launch(package)
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .disabled(deviceOperationInProgress || state.status.isBusy)

                if state.scope == .user {
                    Button(role: .destructive) {
                        pendingForceStop = package
                    } label: {
                        Label(
                            details?.isStopped == true ? "Stopped" : "Force Stop",
                            systemImage: details?.isStopped == true
                                ? "stop.circle.fill" : "stop.circle"
                        )
                    }
                    .disabled(
                        deviceOperationInProgress
                            || state.status.isBusy
                            || details?.isStopped == true
                    )

                    Divider()

                    Button(role: .destructive) {
                        pendingUninstall = package
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .disabled(deviceOperationInProgress || state.status.isBusy)
                }
            } label: {
                Label("Actions for \(package.packageName)", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("App Actions")
        }
        .padding(.vertical, 8)
    }

    private var filteredPackages: [ADBTVInstalledPackage] {
        guard !searchText.isEmpty else {
            return state.packages
        }
        return state.packages.filter {
            $0.packageName.localizedCaseInsensitiveContains(searchText)
                || state.details[$0.packageName]?.displayName?
                    .localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private func appTitle(for package: ADBTVInstalledPackage) -> String {
        state.details[package.packageName]?.displayName ?? package.packageName
    }
}

private struct InstalledAppDetailsView: View {
    @Environment(\.dismiss) private var dismiss

    var package: ADBTVInstalledPackage
    var details: ADBTVInstalledAppDetails?
    var actionsDisabled: Bool
    var allowsUninstall: Bool
    var launch: (ADBTVInstalledPackage) -> Void
    var forceStop: (ADBTVInstalledPackage) -> Void
    var uninstall: (ADBTVInstalledPackage) -> Void

    @State private var confirmsForceStop = false
    @State private var confirmsUninstall = false

    var body: some View {
        NavigationStack {
            List {
                Section("Package Identifier") {
                    HStack(alignment: .top, spacing: 12) {
                        InstalledAppIconView(icon: details?.icon)

                        VStack(alignment: .leading, spacing: 4) {
                            if let displayName = details?.displayName {
                                Text(displayName)
                                    .font(.headline)
                            }
                            Text(package.packageName)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }

                        Spacer(minLength: 0)

                        Button(action: copyPackageName) {
                            Label("Copy Package Identifier", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy Package Identifier")
                    }
                }

                if hasMetadata {
                    Section("Information") {
                        if let versionName = details?.versionName {
                            LabeledContent("Version", value: versionName)
                        }
                        if let versionCode = details?.versionCode {
                            LabeledContent("Version Code", value: String(versionCode))
                        }
                        if let apkByteCount = details?.apkByteCount {
                            LabeledContent(
                                "APK Size",
                                value: ByteCountFormatter.string(
                                    fromByteCount: apkByteCount,
                                    countStyle: .file
                                )
                            )
                        }
                        if let firstInstallDate = details?.firstInstallDate {
                            LabeledContent("Installed") {
                                Text(firstInstallDate, style: .date)
                            }
                        }
                        if let lastUpdateDate = details?.lastUpdateDate {
                            LabeledContent("Updated") {
                                Text(lastUpdateDate, style: .date)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        dismiss()
                        launch(package)
                    } label: {
                        Label("Launch App", systemImage: "play.fill")
                    }
                    .disabled(actionsDisabled)

                    Button(role: .destructive) {
                        confirmsForceStop = true
                    } label: {
                        Label(
                            details?.isStopped == true ? "Stopped" : "Force Stop",
                            systemImage: details?.isStopped == true
                                ? "stop.circle.fill" : "stop.circle"
                        )
                            .foregroundStyle(.red)
                    }
                    .disabled(actionsDisabled || details?.isStopped == true)

                    if allowsUninstall {
                        Button(role: .destructive) {
                            confirmsUninstall = true
                        } label: {
                            Label("Uninstall App", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .disabled(actionsDisabled)
                    }
                }
            }
            .navigationTitle(details?.displayName ?? "App Details")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Force Stop App?",
                isPresented: $confirmsForceStop
            ) {
                Button("Force Stop", role: .destructive) {
                    dismiss()
                    forceStop(package)
                }
            } message: {
                if allowsUninstall {
                    Text("This stops the app, background activity, and playback without removing its data.")
                } else {
                    Text("This is a system app. Stopping it may temporarily affect TV features, and Android may restart it.")
                }
            }
            .confirmationDialog(
                "Uninstall app?",
                isPresented: $confirmsUninstall
            ) {
                Button("Uninstall \(package.packageName)", role: .destructive) {
                    dismiss()
                    uninstall(package)
                }
            } message: {
                Text("This removes \(package.packageName) and its app data from the TV.")
            }
        }
    }

    private var hasMetadata: Bool {
        details?.versionName != nil
            || details?.versionCode != nil
            || details?.apkByteCount != nil
            || details?.firstInstallDate != nil
            || details?.lastUpdateDate != nil
    }

    private func copyPackageName() {
#if os(iOS)
        UIPasteboard.general.string = package.packageName
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(package.packageName, forType: .string)
#endif
    }
}

private struct InstalledAppIconView: View {
    var icon: ADBTVInstalledAppIcon?

    @ViewBuilder
    var body: some View {
#if os(iOS)
        if let icon, let image = UIImage(data: icon.pngData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        } else {
            placeholder
        }
#elseif os(macOS)
        if let icon, let image = NSImage(data: icon.pngData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        } else {
            placeholder
        }
#else
        placeholder
#endif
    }

    private var placeholder: some View {
        Image(systemName: "app.fill")
            .resizable()
            .scaledToFit()
            .padding(10)
            .frame(width: 44, height: 44)
            .foregroundStyle(.secondary)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

private struct DeviceHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var device: ADBTVDeviceSummary
    var repair: () -> Void
    var rename: () -> Void
    var actionsDisabled: Bool

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                identity
                actions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                identity
                Spacer(minLength: 8)
                actions
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let model = device.model {
                Text(model)
                    .font(.headline)
            }
            Text(device.connectionDescription)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(action: repair) {
                Label("Update Connection", systemImage: "network")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(actionsDisabled)
            .help("Update Connection")

            Button(action: rename) {
                Label("Rename Device", systemImage: "pencil")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(actionsDisabled)
            .help("Rename Device")
        }
    }
}

private struct APKInstallPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var installDraft: ADBTVInstallDraft
    var installURLString: Binding<String>
    var canInstall: Bool
    var deviceOperationInProgress: Bool
    var chooseAPK: () -> Void
    var install: () -> Void
    var cancelInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    chooseButton
                    installButton
                    if installDraft.status.canCancel {
                        cancelButton
                    }
                }
            } else {
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
            }

            TextField("App package URL", text: installURLString)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(installDraft.status.isRunning || deviceOperationInProgress)

            if !installURLString.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !installDraft.canPrepareInstallPackage {
                Label("Enter a direct HTTP or HTTPS APK or APKM URL", systemImage: "exclamationmark.triangle")
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
            Label("Choose Package", systemImage: "doc.badge.plus")
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .disabled(installDraft.status.isRunning || deviceOperationInProgress)
    }

    private var installButton: some View {
        Button {
            install()
        } label: {
            Label("Install", systemImage: "square.and.arrow.down")
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
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
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
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
                Label("Downloading package", systemImage: "arrow.down.doc")
                    .foregroundStyle(.secondary)
            }
        case .transferring(let sentByteCount, let totalByteCount):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: transferFraction(sentByteCount, totalByteCount))
                Label("Transferring package", systemImage: "arrow.up.doc")
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
            return "Transferring package"
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var status: ADBTVRemoteStatus
    var text: Binding<String>
    var canSendText: Bool
    var deviceOperationInProgress: Bool
    var unicodeHelperInstallStatus: ADBTVInstallStatus?
    var send: (ADBTVRemoteAction) -> Void
    var sendRepeat: (ADBTVRemoteAction) -> Void
    var sendFromKeyboard: (ADBTVRemoteAction) -> Void
    var sendText: () -> Void
    var startSession: () -> Void
    var stopSession: () -> Void
    var retrySession: () -> Void
    var cancelRemoteOperation: () -> Void
    var installUnicodeInputHelper: () -> Void

    @State private var isMediaControlsExpanded = ProcessInfo.processInfo.arguments.contains(
        "--ui-media-expanded"
    )
    @FocusState private var focusedControl: FocusedControl?

    private enum FocusedControl: Hashable {
        case remote
        case text
    }

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

                RemoteControlButton(action: { sendFromControl(.back) }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.title2.weight(.semibold))
                        .frame(width: 152, height: 44)
                        .background(controlBackground, in: Capsule())
                }
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
            .disabled(
                scenePhase != .active
                    || status.remoteActionsUnavailable
                    || deviceOperationInProgress
            )

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
                        .focused($focusedControl, equals: .text)
                        .disabled(deviceOperationInProgress || status.remoteActionsUnavailable)
                    Button {
                        sendText()
                    } label: {
                        Label("Send Text", systemImage: "paperplane.fill")
                            .labelStyle(.iconOnly)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.white)
                    .disabled(!canSendText || status.remoteActionsUnavailable)
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
                retry: retrySession,
                cancel: cancelRemoteOperation
            )
        }
        .focusable()
        .focused($focusedControl, equals: .remote)
        .focusEffectDisabled()
        .onKeyPress(
            keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape],
            phases: [.down, .repeat]
        ) { press in
            handleKeyPress(press)
        }
        .onAppear {
            focusedControl = .remote
            if scenePhase == .active {
                startSession()
            }
        }
        .onDisappear(perform: stopSession)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                startSession()
            case .background:
                stopSession()
            case .inactive:
                break
            @unknown default:
                break
            }
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

                RemoteControlButton(action: { sendFromControl(.select) }) {
                    Text("OK")
                        .font(.title3.bold())
                        .frame(width: 76, height: 76)
                        .background(Color.accentColor, in: Circle())
                }
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 12)],
                    spacing: 12
                ) {
                    mediaButton(.mediaPrevious, systemImage: "backward.end.fill", title: "Prev")
                    mediaButton(.mediaRewind, systemImage: "backward.fill", title: "Rew")
                    mediaButton(.mediaPlayPause, systemImage: "playpause.fill", title: "Play")
                    mediaButton(.mediaFastForward, systemImage: "forward.fill", title: "FF")
                    mediaButton(.mediaNext, systemImage: "forward.end.fill", title: "Next")
                    mediaButton(.mediaStop, systemImage: "stop.fill", title: "Stop", tint: .red)
                    mediaButton(.enter, systemImage: "return", title: "Enter")
                    mediaButton(.delete, systemImage: "delete.left.fill", title: "Delete")
                    mediaButton(.tab, systemImage: "arrow.right.to.line", title: "Tab")
                }
            } else {
                defaultMediaControls
            }
        }
        .disabled(
            scenePhase != .active
                || status.remoteActionsUnavailable
                || deviceOperationInProgress
        )
    }

    private var defaultMediaControls: some View {
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
    }

    private func mediaButton(
        _ action: ADBTVRemoteAction,
        systemImage: String,
        title: String,
        tint: Color = .primary
    ) -> some View {
        RemoteControlButton(action: { sendFromControl(action) }) {
            mediaButtonLabel(systemImage: systemImage, title: title, tint: tint)
        }
        .accessibilityLabel(action.displayTitle)
    }

    @ViewBuilder
    private func mediaButtonLabel(
        systemImage: String,
        title: String,
        tint: Color
    ) -> some View {
        let label = VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 24)
            Text(title)
                .font(.caption2)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
        .foregroundStyle(tint)

        if dynamicTypeSize.isAccessibilitySize {
            label
                .frame(maxWidth: .infinity, minHeight: 92)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 8))
        } else {
            label
                .frame(width: 54, height: 58)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func directionButton(
        _ action: ADBTVRemoteAction,
        systemImage: String
    ) -> some View {
        RemoteControlButton(
            action: { sendFromControl(action) },
            repeatAction: { sendRepeat(action) }
        ) {
            Image(systemName: systemImage)
                .font(.title2.weight(.bold))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .accessibilityLabel(action.displayTitle)
    }

    private func roundButton(
        _ action: ADBTVRemoteAction,
        systemImage: String,
        foregroundStyle: Color = .primary
    ) -> some View {
        RemoteControlButton(
            action: { sendFromControl(action) },
            repeatAction: action == .volumeDown || action == .volumeUp
                ? { sendRepeat(action) }
                : nil
        ) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 50, height: 50)
                .background(controlBackground, in: Circle())
        }
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
        .disabled(deviceOperationInProgress || status.remoteActionsUnavailable)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard focusedControl != .text else {
            return .ignored
        }

        let action: ADBTVRemoteAction
        switch press.key {
        case .upArrow:
            action = .up
        case .downArrow:
            action = .down
        case .leftArrow:
            action = .left
        case .rightArrow:
            action = .right
        case .return:
            action = .select
        case .escape:
            action = .back
        default:
            return .ignored
        }

        if press.phase == .repeat {
            if action == .up || action == .down || action == .left || action == .right {
                sendRepeat(action)
            }
            return .handled
        }
        sendFromKeyboard(action)
        return .handled
    }

    private func sendFromControl(_ action: ADBTVRemoteAction) {
        focusedControl = .remote
        send(action)
    }

}

private struct RemoteControlButton<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    var action: () -> Void
    var repeatAction: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label()
            .contentShape(Rectangle())
            .opacity(isEnabled ? (isPressed ? 0.65 : 1) : 0.45)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPress() }
                    .onEnded { _ in endPress() }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    endPress()
                }
            }
            .onDisappear(perform: endPress)
    }

    private func beginPress() {
        guard isEnabled, !isPressed else {
            return
        }
        isPressed = true
        action()
        guard let repeatAction else {
            return
        }
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            for _ in 0..<62 where !Task.isCancelled {
                repeatAction()
                try? await Task.sleep(for: .milliseconds(125))
            }
        }
    }

    private func endPress() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}

private struct RemoteStatusView: View {
    var status: ADBTVRemoteStatus
    var retry: () -> Void
    var cancel: () -> Void

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .connecting:
            connectionStatus("Connecting to TV")
        case .reconnecting:
            connectionStatus("Reconnecting to TV")
        case .catchingUp:
            Label("Remote is catching up", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        case .connectionFailed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 10) {
                RemoteFailureView(
                    userMessage: userMessage,
                    diagnosticDetail: diagnosticDetail
                )
                Button(action: retry) {
                    Label("Retry Connection", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
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

    private func connectionStatus(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .foregroundStyle(.secondary)
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

struct DiagnosticDisclosure: View {
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
