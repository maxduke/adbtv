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
    @State private var isBackupPresented = false
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
    @State private var quickLaunchOperationID: UUID?
    @State private var installedAppDetailsCoordinator = ADBTVInstalledAppDetailsCoordinator()
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
        initiallyPresentsAddDevice: Bool = false,
        initiallyPresentsPairDevice: Bool = false,
        initiallyPresentsConnectionRepair: Bool = false,
        initiallyPresentsDeviceRename: Bool = false,
        initiallyPresentsInstalledApps: Bool = false,
        initiallyPresentsDeviceTools: Bool = false,
        initiallyPresentsFileBrowser: Bool = false,
        initiallyPresentsBackup: Bool = false
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
        self._isBackupPresented = State(initialValue: initiallyPresentsBackup)
        self._isAddDevicePresented = State(initialValue: initiallyPresentsAddDevice)
        self._isPairDevicePresented = State(initialValue: initiallyPresentsPairDevice)
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
                Section(adbTVLocalized("Devices")) {
                    if model.devices.isEmpty {
                        emptyLibraryContent
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
                    Section(adbTVLocalized("Discovery")) {
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
                        Label(adbTVLocalized("About"), systemImage: "info.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help(adbTVLocalized("About"))

                    Button {
                        isBackupPresented = true
                    } label: {
                        Label(adbTVLocalized("Backup and Restore"), systemImage: "externaldrive")
                            .labelStyle(.iconOnly)
                    }
                    .help(adbTVLocalized("Backup and Restore"))
                    .disabled(model.activeDeviceOperation != nil || deviceConnectionState.isConnecting)

                    Menu {
                        Button {
                            model.prepareManualPairing()
                            isPairDevicePresented = true
                        } label: {
                            Label(adbTVLocalized("Pair with Code"), systemImage: "key")
                        }

#if os(iOS) && canImport(AVFoundation)
                        if bonjourCapability.isAvailable {
                            Button {
                                presentQRCodeScanner()
                            } label: {
                                Label(adbTVLocalized("Scan Pairing QR Code"), systemImage: "qrcode.viewfinder")
                            }
                        }
#endif

                        Button {
                            isAddDevicePresented = true
                        } label: {
                            Label(adbTVLocalized("Add Manually"), systemImage: "square.and.pencil")
                        }
                    } label: {
                        Label(adbTVLocalized("Add Device"), systemImage: "plus")
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
                        installedAppReadOnlyRefreshInProgress:
                            installedAppsState.deviceID == device.id
                                && installedAppsState.status.isActivityRefresh,
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
                        selectAppsMode: { mode in
                            selectInstalledAppsMode(mode, on: device)
                        },
                        retryInstalledAppDetails: {
                            startInstalledAppDetailsLoad(
                                installedAppsState.pendingDetailsPackages,
                                on: device,
                                forActivity: installedAppsState.mode == .active
                            )
                        },
                        loadActiveSystemSnapshot: { expectedUserID in
                            runInstalledAppCommand(
                                .activeSystemSnapshot(expectedUserID: expectedUserID),
                                on: device
                            )
                        },
                        launchInstalledApp: { package in
                            runInstalledAppCommand(.launch(package), on: device)
                        },
                        loadQuickLaunchUser: { try await Self.loadQuickLaunchUser(on: device) },
                        launchQuickApp: { package, userID in
                            try await launchQuickApp(package, userID: userID, on: device)
                        },
                        forceStopInstalledApp: { package in
                            runInstalledAppCommand(.forceStop(package), on: device)
                        },
                        uninstallInstalledApp: { package in
                            runInstalledAppCommand(.uninstall(package), on: device)
                        },
                        openInstalledAppSettings: { package in
                            runInstalledAppCommand(.openSettings(package), on: device)
                        },
                        clearInstalledAppData: { package in
                            runInstalledAppCommand(.clearData(package), on: device)
                        },
                        disableSystemApp: { package, userID in
                            runInstalledAppCommand(
                                .disable(package, userID: userID),
                                on: device
                            )
                        },
                        restoreSystemAppDefault: { package, userID in
                            runInstalledAppCommand(
                                .restoreDefault(package, userID: userID),
                                on: device
                            )
                        },
                        cancelInstalledAppOperation: {
                            cancelInstalledAppOperation()
                        },
                        cancelActivityRefresh: cancelActivityRefreshIfNeeded,
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
                } else if model.devices.isEmpty {
                    ScrollView {
                        emptyLibraryContent
                            .frame(maxWidth: 520)
                            .frame(maxWidth: .infinity)
                    }
                    .navigationTitle("ADB TV")
                } else {
                    ContentUnavailableView(adbTVLocalized("Select a Device"), systemImage: "tv.and.hifispeaker.fill")
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
        .sheet(isPresented: $isBackupPresented) { backupSheet }
#if os(iOS) && canImport(AVFoundation)
        .sheet(isPresented: $isQRCodeScannerPresented) {
            NavigationStack {
                ADBQRCodeScannerView(
                    onPayload: handleQRCodePayload,
                    onFailure: handleQRCodeScannerFailure
                )
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(adbTVLocalized("Scan Pairing QR"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            isQRCodeScannerPresented = false
                        } label: {
                            Label(adbTVLocalized("Cancel"), systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
        .alert(
            adbTVLocalized("Camera unavailable"),
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
                Button(adbTVLocalized("Open Settings")) {
                    openURL(settingsURL)
                }
            }
            Button(adbTVLocalized("Copy Technical Details")) {
                UIPasteboard.general.string = detail.formattedDescription
            }
            Button(adbTVLocalized("OK"), role: .cancel) {}
        } message: { _ in
            Text(adbTVLocalized("Camera access is unavailable. Check Settings, or use Pair with Code. Copy Technical Details for more information."))
        }
#endif
        .alert(
            adbTVLocalized("Device Library issue"),
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
            Button(adbTVLocalized("Copy Technical Details")) {
                UIPasteboard.general.string = diagnosticDetail.formattedDescription
            }
#endif
            Button(adbTVLocalized("OK"), role: .cancel) {}
        } message: { diagnosticDetail in
            Text(diagnosticDetail.context["operation"] == "loadDevices"
                ? adbTVLocalized(diagnosticDetail.summary)
                : adbTVLocalized("Could not update the Device Library. Copy Technical Details for more information."))
        }
        .confirmationDialog(
            adbTVLocalized("Replace Input Helper?"),
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
            Button(adbTVLocalized("Replace Helper"), role: .destructive) {
                helperReplacementDevice = nil
                startInstall(
                    for: device,
                    isUnicodeInputHelper: true,
                    replacingUnicodeInputHelper: true
                )
            }
        } message: { _ in
            Text(
                adbTVLocalized("Android cannot update the installed helper because it was signed differently. Replacing it removes only the helper, then installs this version. No TV app data is affected.")
            )
        }
#if os(iOS)
        .sheet(isPresented: $isFileImporterPresented) {
            ADBTVAPKDocumentPicker { result in
                isFileImporterPresented = false
                switch result {
                case .success(let urls):
                    if let url = urls.first { handlePackageSelection(.success(url)) }
                case .failure(let error):
                    handlePackageSelection(.failure(error))
                }
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
            quickLaunchOperationID = nil
            installedAppDetailsCoordinator.cancel()
            deviceToolsTask?.cancel()
            deviceToolsOperationID = nil
            deviceConnectionTask?.cancel()
            model.cancelActiveDeviceOperation()
            cancelPairing()
            stopDiscovery()
        }
    }

    @MainActor
    @ViewBuilder
    private var backupSheet: some View {
        let content = ADBTVConfigurationBackupView(deviceStore: deviceStore, restore: restoreConfiguration)
#if os(iOS)
        if #available(iOS 18, *) { content.presentationSizing(.page) }
        else { content }
#else
        content
#endif
    }

    @MainActor
    private func restoreConfiguration(_ plan: ADBTVConfigurationRestorePlan, selectedIDs: Set<UUID>) throws -> ADBTVConfigurationRestoreReport {
        guard model.activeDeviceOperation == nil, !deviceConnectionState.isConnecting else {
            throw ADBTVConfigurationBackupError.busy
        }
        let result = try ADBTVConfigurationBackupStore(deviceStore: deviceStore).restore(plan, selectedIDs: selectedIDs)
        stopRemoteSession()
        selectSavedDevice(id: nil)
        model.devices = result.devices
        return result
    }

    private var emptyLibraryContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(adbTVLocalized("Connect Your TV"))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button {
                    model.prepareManualPairing()
                    isPairDevicePresented = true
                } label: {
                    Text(adbTVLocalized("Pair with Code"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .adbTVProminentButton()

                Button {
                    isAddDevicePresented = true
                } label: {
                    Text(adbTVLocalized("Connect by IP Address"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)

            }
            .disabled(model.activeDeviceOperation != nil || deviceConnectionState.isConnecting)

            Text(adbTVLocalized("Connect to the same Wi-Fi as your TV and enable ADB debugging in its developer options."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(adbTVLocalized("Use a pairing code for Wireless debugging, or connect by IP when network ADB is already enabled."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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
            cancelActivityRefreshIfNeeded()
            stopRemoteSession()
            automaticDiscoveryPolicy.recordSceneLeftActiveState()
            if automaticDiscoveryPolicy.shouldSuspendDiscovery(status: model.discoveryStatus) {
                stopDiscovery()
            }
        case .inactive:
            cancelActivityRefreshIfNeeded()
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
                    userMessage: adbTVLocalized("Select an APK or APKM file."),
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
                userMessage: adbTVLocalized("Could not open the selected app package."),
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
        cancelActivityRefreshIfNeeded()
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
        if saveDevices() {
            for id in ids where !model.devices.contains(where: { $0.id == id }) {
                ADBTVQuickLaunchStore().removeDevice(id)
            }
        }
    }

    @discardableResult
    private func saveDevices() -> Bool {
        do {
            try deviceStore.saveDevices(model.devices)
            return true
        } catch {
            devicePersistenceError = DiagnosticDetail(
                summary: String(describing: error),
                context: ["operation": "saveDevices"]
            )
            return false
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
            userMessage: adbTVLocalized("Device discovery is not available on this platform."),
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
            return adbTVLocalized("Automatic discovery is unavailable in this signed build. Add the TV manually.")
        case .localNetworkDenied:
            return adbTVLocalized("Local Network access is off. Enable it in Settings to discover Android TV devices.")
        case .other:
            return adbTVLocalized("Could not discover Android TV devices.")
        }
    }

    private static func discoveryWaitingUserMessage(
        for failure: ADBBonjourDiscoveryFailure
    ) -> String {
        switch failure.reason {
        case .bonjourCapabilityDenied:
            return adbTVLocalized("Automatic discovery requires an Apple-approved Multicast Networking entitlement.")
        case .localNetworkDenied:
            return adbTVLocalized("Local Network access is off. Enable it in Settings to discover Android TV devices.")
        case .other:
            return adbTVLocalized("Waiting for the local network before discovering Android TV devices.")
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
                        userMessage: adbTVLocalized("Pairing succeeded, but the app could not connect to the TV."),
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
                        userMessage: adbTVLocalized("The QR pairing service was not found on the local network."),
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
                        userMessage: adbTVLocalized("Pairing succeeded, but the TV connection service was not found."),
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
            return adbTVLocalized("Pairing timed out. Check the TV and try again.")
        }
        return adbTVLocalized("Could not pair with this Android TV.")
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
                        ? adbTVLocalized("Could not replace the Input Helper.")
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
                userMessage: adbTVLocalized("The Unicode Input Helper is missing from this app build."),
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
            let manager = ADBTVInstalledAppManager()
            let snapshot = try await manager.list(using: &connection)
            try await manager.uninstall(package, userID: snapshot.userID, using: &connection)
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
            return adbTVLocalized("App installation timed out.")
        }
        if error is ADBAPKValidationError {
            return adbTVLocalized("The selected file is not a valid APK.")
        }
        if error is ADBTVAPKMExtractionError {
            return adbTVLocalized("The selected file is not a valid APKM bundle.")
        }
        if error is ADBTVInstallFileError {
            return adbTVLocalized("Could not read the selected app package.")
        }
        if error is ADBTVInstallDownloadError {
            return adbTVLocalized("Could not download the app package.")
        }

        return adbTVLocalized("Could not install the app package.")
    }

    private func startRemoteSession(for device: ADBTVDeviceSummary) {
#if DEBUG
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-") }) else {
            return
        }
#endif
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
        guard let session = detachRemoteSession() else { return }
        Task { await session.close() }
    }

    private func detachRemoteSession() -> ADBTVRemoteSession? {
        guard let session = remoteSession else { return nil }
        remoteSession = nil
        remoteSessionDeviceID = nil
        remoteSessionToken = nil
        remoteInputTask?.cancel()
        remoteInputTask = nil
        if model.activeDeviceOperation == nil {
            model.remoteStatus = .idle
        }
        return session
    }

    @MainActor
    private func launchQuickApp(
        _ package: ADBTVInstalledPackage, userID: Int, on device: ADBTVDeviceSummary
    ) async throws {
        try Task.checkCancellation()
        guard model.startInstalledAppOperation(on: device.id) else {
            throw ADBTVQuickLaunchError.deviceBusy
        }
        let token = UUID()
        quickLaunchOperationID = token
        defer {
            if quickLaunchOperationID == token {
                quickLaunchOperationID = nil
                _ = model.finishInstalledAppOperation(on: device.id)
                if model.selectedDeviceID == device.id, scenePhase == .active {
                    startRemoteSession(for: device)
                }
            }
        }
        // Drop pending navigation before changing the TV's foreground app.
        // An already-dispatched key remains uncertain and is never replayed.
        let session = detachRemoteSession()
        await session?.close()
        try Task.checkCancellation()
        _ = try await Self.performInstalledAppCommand(.launch(package), on: device, userID: userID)
        if installedAppsState.deviceID == device.id, installedAppsState.mode == .active {
            installedAppsState.status = .idle
        }
    }

    private static func loadQuickLaunchUser(on device: ADBTVDeviceSummary) async throws -> Int {
#if canImport(Network) && canImport(Security)
        return try await ADBTVOperationTimeoutPolicy.installedApps.run(operation: .installedApps) {
            var connection = try await connectedDevice(for: device)
            defer { connection.cancel() }
            return try await ADBTVInstalledAppManager().activeUserID(using: &connection)
        }
#else
        throw ADBTVInstalledAppOperationError.unsupportedPlatform
#endif
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
        let userID = installedAppsState.userID
        cancelInstalledAppDetailsLoad()
        switch command {
        case .list(let scope):
            let mode: ADBTVAppsMode = scope == .user ? .user : .system
            installedAppsState.prepareListRefresh(mode: mode)
        case .activitySnapshot:
            installedAppsState.prepareActivityRefresh()
        case .activeSystemSnapshot:
            break
        case .launch, .forceStop, .uninstall, .openSettings, .clearData,
             .disable, .restoreDefault:
            break
        }
        installedAppsState.status = command.inProgressStatus
        let operationID = UUID()
        installedAppsOperationID = operationID

        installedAppsTask = Task {
            let completion: ADBTVInstalledAppCompletion
            do {
                completion = .success(try await Self.performInstalledAppCommand(
                    command,
                    on: device,
                    userID: userID
                ))
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                completion = .failure(
                    userMessage: Self.appUserChanged(error)
                        ? adbTVLocalized("The TV user changed. Refresh Apps before trying again.")
                        : command.failureMessage,
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

    private func selectInstalledAppsMode(
        _ mode: ADBTVAppsMode,
        on device: ADBTVDeviceSummary
    ) {
        cancelActivityRefreshIfNeeded()
        installedAppsState.pendingForceStopPackage = nil
        installedAppsState.pendingClearDataPackage = nil
        if let scope = mode.scope {
            runInstalledAppCommand(.list(scope), on: device)
        } else {
            runInstalledAppCommand(.activitySnapshot, on: device)
        }
    }

    private func cancelActivityRefreshIfNeeded() {
        guard installedAppsState.status.isActivityRefresh else {
            return
        }
        cancelInstalledAppOperation(message: nil)
    }

    @discardableResult
    private func cancelInstalledAppOperation(message: String? = adbTVLocalized("Cancelled.")) -> Bool {
        guard case .installedApps(let deviceID) = model.activeDeviceOperation else {
            return false
        }
        installedAppsTask?.cancel()
        installedAppsTask = nil
        installedAppsOperationID = nil
        guard model.cancelInstalledAppOperation(on: deviceID),
              installedAppsState.deviceID == deviceID else {
            return false
        }
        installedAppsState.pendingForceStopPackage = nil
        installedAppsState.pendingClearDataPackage = nil
        installedAppsState.status = .ready(message: message)
        return true
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

        var refreshesActivity = false
        switch completion {
        case .success(.listedUserApps(let snapshot)):
            installedAppsState.recordListSnapshot(snapshot.packages, userID: snapshot.userID)
            startInstalledAppDetailsLoad(snapshot.packages, on: device)
        case .success(.listedSystemApps(let snapshot)):
            installedAppsState.recordListSnapshot(
                snapshot.packages, userID: snapshot.userID, systemSnapshot: snapshot
            )
            startInstalledAppDetailsLoad(snapshot.packages, on: device)
        case .success(.loadedActivity(let snapshot)):
            installedAppsState.userID = snapshot.userID
            let forceStoppedPackage = installedAppsState.pendingForceStopPackage
            let forceStoppedName = forceStoppedPackage.flatMap {
                installedAppsState.activityDetails[$0.packageName]?.displayName
            } ?? forceStoppedPackage?.packageName
            let clearedDataPackage = installedAppsState.pendingClearDataPackage
            let clearedDataName = clearedDataPackage.flatMap {
                installedAppsState.activityDetails[$0.packageName]?.displayName
            } ?? clearedDataPackage?.packageName
            installedAppsState.activitySnapshot = snapshot
            installedAppsState.activityDetails = [:]
            installedAppsState.activeSystemSnapshot = nil
            installedAppsState.pendingForceStopPackage = nil
            installedAppsState.pendingClearDataPackage = nil
            if let forceStoppedPackage, let forceStoppedName {
                let remainsActive = snapshot.apps.contains {
                    $0.package == forceStoppedPackage
                }
                installedAppsState.status = .ready(
                    message: remainsActive
                        ? adbTVLocalized("Android kept or restarted %@; it remains active.", String(describing: forceStoppedName))
                        : adbTVLocalized("Stopped %@.", String(describing: forceStoppedName))
                )
            } else if let clearedDataPackage, let clearedDataName {
                let remainsActive = snapshot.apps.contains {
                    $0.package == clearedDataPackage
                }
                installedAppsState.status = .ready(
                    message: remainsActive
                        ? adbTVLocalized("Cleared data for %@, but Android reports it active.", String(describing: clearedDataName))
                        : adbTVLocalized("Cleared data for %@.", String(describing: clearedDataName))
                )
            } else {
                installedAppsState.status = .ready(message: nil)
            }
            startInstalledAppDetailsLoad(
                snapshot.apps.map(\.package),
                on: device,
                forActivity: true
            )
        case .success(.loadedActiveSystemSnapshot(let snapshot)):
            installedAppsState.activeSystemSnapshot = snapshot
            installedAppsState.status = .ready(message: nil)
        case .success(.launched(let package)):
            if installedAppsState.mode == .active {
                installedAppsState.pendingForceStopPackage = nil
                installedAppsState.pendingClearDataPackage = nil
                refreshesActivity = true
                break
            }
            installedAppsState.details[package.packageName]?.isStopped = false
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.status = .ready(
                message: adbTVLocalized("Launched %@.", String(describing: name))
            )
        case .success(.stopped(let package)):
            if installedAppsState.mode == .active {
                installedAppsState.pendingForceStopPackage = package
                installedAppsState.pendingClearDataPackage = nil
                refreshesActivity = true
                break
            }
            if installedAppsState.details[package.packageName] == nil {
                installedAppsState.details[package.packageName] = ADBTVInstalledAppDetails(
                    isStopped: true
                )
            } else {
                installedAppsState.details[package.packageName]?.isStopped = true
            }
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.status = .ready(message: adbTVLocalized("Stopped %@.", String(describing: name)))
        case .success(.uninstalled(let package)):
            if installedAppsState.mode == .active {
                installedAppsState.pendingForceStopPackage = nil
                installedAppsState.pendingClearDataPackage = nil
                refreshesActivity = true
                break
            }
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.packages.removeAll { $0 == package }
            installedAppsState.details.removeValue(forKey: package.packageName)
            installedAppsState.status = .ready(
                message: adbTVLocalized("Uninstalled %@.", String(describing: name))
            )
        case .success(.openedSettings(let package)):
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? installedAppsState.activityDetails[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.status = .ready(
                message: adbTVLocalized("Opened App Settings for %@ on the TV.", String(describing: name))
            )
        case .success(.clearedData(let package)):
            if installedAppsState.mode == .active {
                installedAppsState.pendingForceStopPackage = nil
                installedAppsState.pendingClearDataPackage = package
                refreshesActivity = true
                break
            }
            if installedAppsState.details[package.packageName] == nil {
                installedAppsState.details[package.packageName] = ADBTVInstalledAppDetails(
                    isStopped: true
                )
            } else {
                installedAppsState.details[package.packageName]?.isStopped = true
            }
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.status = .ready(message: adbTVLocalized("Cleared data for %@.", String(describing: name)))
        case .success(.disabled(let package)):
            if installedAppsState.mode == .active {
                installedAppsState.pendingForceStopPackage = nil
                installedAppsState.pendingClearDataPackage = nil
                refreshesActivity = true
                break
            }
            installedAppsState.setSystemState(.disabled, for: package)
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            installedAppsState.status = .ready(message: adbTVLocalized("Disabled %@.", String(describing: name)))
        case .success(.restoredDefault(let package, let state)):
            if installedAppsState.mode == .active {
                installedAppsState.pendingForceStopPackage = nil
                installedAppsState.pendingClearDataPackage = nil
                refreshesActivity = true
                break
            }
            installedAppsState.setSystemState(state, for: package)
            let name = installedAppsState.details[package.packageName]?.displayName
                ?? package.packageName
            let message = state == .enabled
                ? adbTVLocalized("Restored %@ to Android default.", String(describing: name))
                : adbTVLocalized("Android default keeps %@ disabled.", String(describing: name))
            installedAppsState.status = .ready(message: message)
        case .failure(let userMessage, let diagnosticDetail):
            installedAppsState.pendingForceStopPackage = nil
            installedAppsState.pendingClearDataPackage = nil
            installedAppsState.status = .failed(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        }
        if refreshesActivity {
            installedAppsState.status = .ready(message: nil)
            runInstalledAppCommand(.activitySnapshot, on: device)
        } else if case .success = completion,
                  installedAppsState.detailsStatus == .idle,
                  !installedAppsState.pendingDetailsPackages.isEmpty {
            startInstalledAppDetailsLoad(
                installedAppsState.pendingDetailsPackages,
                on: device,
                forActivity: installedAppsState.mode == .active
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
        on device: ADBTVDeviceSummary,
        forActivity: Bool = false
    ) {
        cancelInstalledAppDetailsLoad()
        guard !packages.isEmpty, let userID = installedAppsState.userID else {
            return
        }

        installedAppsState.detailsStatus = .loading
        installedAppsState.pendingDetailsPackages = packages
        installedAppDetailsCoordinator.start(
            packages,
            userID: userID,
            loadPage: { page, userID in
                try await Self.loadInstalledAppDetails(page, userID: userID, on: device)
            }
        ) { event in
            guard installedAppsState.deviceID == device.id,
                  installedAppsState.userID == userID else { return }
            switch event {
            case .page(let page, let details):
                installedAppsState.recordDetailsPage(details, packages: page, forActivity: forActivity)
            case .finished(let result):
                installedAppsState.finishDetailsLoad(result)
            case .failed(let error):
                installedAppsState.detailsStatus = .failed(String(describing: error))
                if Self.appUserChanged(error) {
                    installedAppsState.userID = nil
                    installedAppsState.pendingDetailsPackages = []
                    installedAppsState.status = .failed(
                        userMessage: adbTVLocalized("The TV user changed. Refresh Apps before trying again."),
                        diagnosticDetail: DiagnosticDetail(
                            summary: String(describing: error),
                            context: ["operation": "loadInstalledAppDetails"]
                        )
                    )
                }
            }
        }
    }

    private static func appUserChanged(_ error: Error) -> Bool {
        guard let error = error as? ADBTVInstalledAppError else { return false }
        if case .activeUserChanged = error { return true }
        return false
    }

    private static func requiredAppUserID(_ userID: Int?) throws -> Int {
        guard let userID else {
            throw ADBTVInstalledAppOperationError.missingUserSnapshot
        }
        return userID
    }

    private func cancelInstalledAppDetailsLoad() {
        installedAppDetailsCoordinator.cancel()
        if installedAppsState.detailsStatus == .loading {
            installedAppsState.detailsStatus = .idle
        }
    }

    private static func loadInstalledAppDetails(
        _ packages: [ADBTVInstalledPackage],
        userID: Int,
        on device: ADBTVDeviceSummary
    ) async throws -> [String: ADBTVInstalledAppDetails] {
#if canImport(Network) && canImport(Security)
        return try await ADBTVOperationTimeoutPolicy.installedApps.run(
            operation: .installedApps
        ) {
            var connection = try await connectedDevice(for: device)
            defer { connection.cancel() }
            return try await ADBTVInstalledAppManager().details(
                for: packages,
                userID: userID,
                using: &connection
            )
        }
#else
        throw ADBTVInstalledAppOperationError.unsupportedPlatform
#endif
    }

    private static func performInstalledAppCommand(
        _ command: ADBTVInstalledAppCommand,
        on device: ADBTVDeviceSummary,
        userID: Int?
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
                if scope == .system {
                    return .listedSystemApps(
                        try await manager.systemSnapshot(using: &connection)
                    )
                }
                return .listedUserApps(
                    try await manager.list(scope: .user, using: &connection)
                )
            case .activitySnapshot:
                return .loadedActivity(
                    try await manager.activitySnapshot(using: &connection)
                )
            case .activeSystemSnapshot(let expectedUserID):
                let snapshot = try await manager.systemSnapshot(using: &connection)
                guard snapshot.userID == expectedUserID else {
                    throw ADBTVInstalledAppError.activeUserChanged(
                        expected: expectedUserID,
                        actual: snapshot.userID
                    )
                }
                return .loadedActiveSystemSnapshot(snapshot)
            case .launch(let package):
                try await manager.launch(
                    package, userID: requiredAppUserID(userID), using: &connection
                )
                return .launched(package)
            case .forceStop(let package):
                try await manager.forceStop(
                    package, userID: requiredAppUserID(userID), using: &connection
                )
                return .stopped(package)
            case .uninstall(let package):
                try await manager.uninstall(
                    package, userID: requiredAppUserID(userID), using: &connection
                )
                return .uninstalled(package)
            case .openSettings(let package):
                try await manager.openAppSettings(
                    package, userID: requiredAppUserID(userID), using: &connection
                )
                return .openedSettings(package)
            case .clearData(let package):
                try await manager.clearData(
                    package, userID: requiredAppUserID(userID), using: &connection
                )
                return .clearedData(package)
            case .disable(let package, let userID):
                try await manager.disable(package, userID: userID, using: &connection)
                return .disabled(package)
            case .restoreDefault(let package, let userID):
                let state = try await manager.restoreDefault(
                    package,
                    userID: userID,
                    using: &connection
                )
                return .restoredDefault(package, state: state)
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
                    ? adbTVLocalized("The TV did not respond in time.")
                    : adbTVLocalized("Could not connect to the TV."),
                diagnosticDetail: Self.remoteSessionDiagnosticDetail(failure, device: device)
            )
            Self.remoteWarningFeedback()
        case .reconnectFailed(let actionFailure, let connectionFailure):
            var detail = Self.remoteSessionDiagnosticDetail(connectionFailure, device: device)
            detail.context["failedAction"] = actionFailure.action.map { String(describing: $0) } ?? "unknown"
            detail.context["actionFailure"] = actionFailure.summary
            model.remoteStatus = .connectionFailed(
                userMessage: adbTVLocalized("Connection to the TV was lost."),
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
            return adbTVLocalized("The TV did not respond in time.")
        }
        if let shellError = error as? ADBTVRemoteShellInvocationError,
           case let .commandFailed(exitCode, _) = shellError {
            if (21 ... 22).contains(exitCode) {
                return adbTVLocalized("Install the Unicode Input Helper, then try sending the text again.")
            }
            if exitCode == 24 {
                return adbTVLocalized("Could not restore the previous TV keyboard. Select it in the TV settings.")
            }
            if exitCode == 23 || exitCode == 25 {
                return adbTVLocalized("Focus a text field on the TV, then try sending the Unicode text again.")
            }
        }
        return adbTVLocalized("Could not send text.")
    }

    private static func deviceToolUserMessage(
        for operation: ADBTVDeviceToolOperation,
        error: Error
    ) -> String {
        if case .screenshot = operation,
           let toolsError = error as? ADBTVDeviceToolsError,
           case .screenshotUnavailable = toolsError {
            return adbTVLocalized("Screenshot unavailable. The current app or TV may block screen capture.")
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
    case activitySnapshot
    case activeSystemSnapshot(expectedUserID: Int)
    case launch(ADBTVInstalledPackage)
    case forceStop(ADBTVInstalledPackage)
    case uninstall(ADBTVInstalledPackage)
    case openSettings(ADBTVInstalledPackage)
    case clearData(ADBTVInstalledPackage)
    case disable(ADBTVInstalledPackage, userID: Int)
    case restoreDefault(ADBTVInstalledPackage, userID: Int)

    var inProgressStatus: ADBTVInstalledAppsStatus {
        switch self {
        case .list:
            return .loading
        case .activitySnapshot:
            return .loadingActivity
        case .activeSystemSnapshot:
            return .loadingSystemControl
        case .launch(let package):
            return .launching(package)
        case .forceStop(let package):
            return .stopping(package)
        case .uninstall(let package):
            return .uninstalling(package)
        case .openSettings(let package):
            return .openingSettings(package)
        case .clearData(let package):
            return .clearingData(package)
        case .disable(let package, _):
            return .disabling(package)
        case .restoreDefault(let package, _):
            return .restoringDefault(package)
        }
    }

    var operationName: String {
        switch self {
        case .list(let scope):
            return scope == .user ? "listUserApps" : "listSystemApps"
        case .activitySnapshot:
            return "loadAppActivity"
        case .activeSystemSnapshot:
            return "loadActiveSystemAppProtection"
        case .launch:
            return "launchInstalledApp"
        case .forceStop:
            return "forceStopInstalledApp"
        case .uninstall:
            return "uninstallInstalledApp"
        case .openSettings:
            return "openInstalledAppSettings"
        case .clearData:
            return "clearInstalledAppData"
        case .disable:
            return "disableSystemApp"
        case .restoreDefault:
            return "restoreSystemAppDefault"
        }
    }

    var packageName: String? {
        switch self {
        case .list, .activitySnapshot, .activeSystemSnapshot:
            return nil
        case .launch(let package),
             .forceStop(let package),
             .uninstall(let package),
             .openSettings(let package),
             .clearData(let package),
             .disable(let package, _),
             .restoreDefault(let package, _):
            return package.packageName
        }
    }

    var failureMessage: String {
        switch self {
        case .list:
            return adbTVLocalized("Could not load installed apps.")
        case .activitySnapshot:
            return adbTVLocalized("Could not load active apps.")
        case .activeSystemSnapshot:
            return adbTVLocalized("Could not load system controls.")
        case .launch:
            return adbTVLocalized("Could not launch this app.")
        case .forceStop:
            return adbTVLocalized("Could not stop this app.")
        case .uninstall:
            return adbTVLocalized("Could not uninstall this app.")
        case .openSettings:
            return adbTVLocalized("Could not open App Settings on the TV.")
        case .clearData:
            return adbTVLocalized("Could not clear this app's data.")
        case .disable:
            return adbTVLocalized("Could not disable this system app.")
        case .restoreDefault:
            return adbTVLocalized("Could not restore this system app.")
        }
    }
}

private enum ADBTVInstalledAppResult: Sendable {
    case listedUserApps(ADBTVInstalledAppSnapshot)
    case listedSystemApps(ADBTVSystemAppSnapshot)
    case loadedActivity(ADBTVAppActivitySnapshot)
    case loadedActiveSystemSnapshot(ADBTVSystemAppSnapshot)
    case launched(ADBTVInstalledPackage)
    case stopped(ADBTVInstalledPackage)
    case uninstalled(ADBTVInstalledPackage)
    case openedSettings(ADBTVInstalledPackage)
    case clearedData(ADBTVInstalledPackage)
    case disabled(ADBTVInstalledPackage)
    case restoredDefault(ADBTVInstalledPackage, state: ADBTVInstalledAppState)
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

private enum ADBTVInstalledAppOperationError: Error {
    case unsupportedPlatform
    case missingUserSnapshot
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
