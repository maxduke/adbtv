import ADBClientCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

public struct ADBTVRootView: View {
#if os(iOS)
    @Environment(\.openURL) private var openURL
#endif

    private let deviceStore: ADBTVDeviceStore

    @State private var model: ADBTVAppModel
    @State private var isFileImporterPresented = false
    @State private var isAddDevicePresented = false
    @State private var isPairDevicePresented = false
    @State private var devicePersistenceError: DiagnosticDetail?
    @State private var installTask: Task<Void, Never>?
    @State private var remoteTask: Task<Void, Never>?
    @State private var pairingTask: Task<Void, Never>?
    @State private var automaticDiscoveryPolicy = ADBTVAutomaticDiscoveryPolicy()
#if os(iOS) && canImport(AVFoundation)
    @State private var isQRCodeScannerPresented = false
    @State private var qrScannerError: DiagnosticDetail?
#endif
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

#if os(iOS) && canImport(AVFoundation)
                        Button {
                            presentQRCodeScanner()
                        } label: {
                            Label("Scan Pairing QR Code", systemImage: "qrcode.viewfinder")
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
                    remoteTextString: Binding(
                        get: { model.remoteTextString },
                        set: { model.setRemoteTextString($0) }
                    ),
                    canInstall: model.canInstallSelectedPackage,
                    canSendRemoteText: model.canSendRemoteText,
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
        .sheet(isPresented: $isPairDevicePresented) {
            PairDeviceView(
                draft: $model.pairingDraft,
                status: model.pairingStatus,
                startPairing: startPairing,
                cancelPairing: cancelPairing
            )
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
        .task {
            if automaticDiscoveryPolicy.shouldStartDiscovery(status: model.discoveryStatus) {
                startDiscovery()
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
            if let device = model.updateDiscoveredServices(services) {
                pairingTask?.cancel()
                pairingTask = nil
                verifyPairingConnection(device)
            }
            if model.selectQRCodePairingServiceIfAvailable() {
                startPairing()
            }
        }, failureHandler: { failure in
            browser.cancel()
            discoveryBrowser = nil
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
        case .noAuthorization:
            return "Bonjour discovery is not authorized. Check Local Network access in Settings, then retry."
        case .localNetworkDenied:
            return "Local Network access is off. Enable it in Settings to discover Android TV devices."
        case .other:
            return "Could not discover Android TV devices."
        }
    }

    private static func discoveryDiagnosticContext(
        for failure: ADBBonjourDiscoveryFailure
    ) -> [String: String] {
        var context = [
            "operation": "bonjourDiscovery",
            "reason": failure.reason.rawValue
        ]
        if let dnsErrorCode = failure.dnsErrorCode {
            context["dnsErrorCode"] = String(dnsErrorCode)
        }
        return context
    }
#endif

    private func prepareDiscoveredPairing(_ service: ADBDiscoveredService) {
        guard service.kind == .pairing else {
            return
        }

        model.prepareDiscoveredPairing(service: service)
        isPairDevicePresented = true
    }

#if os(iOS) && canImport(AVFoundation)
    private func presentQRCodeScanner() {
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
        model.recordInstallEvent(.phaseStarted(.validatePackage))

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
                            model.recordInstallEvent(event)
                        }
                    }
                ))
            } catch is CancellationError {
                return
            } catch {
                completion = .failure(
                    userMessage: Self.installUserMessage(for: error),
                    diagnosticDetail: Self.installDiagnosticDetail(error, device: device)
                )
            }

            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard !Task.isCancelled else {
                    return
                }
                completeInstall(completion)
            }
        }
    }

    private func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        model.cancelInstall()
    }

    private static func installPackage(
        for device: ADBTVDeviceSummary,
        using installModel: ADBTVAppModel,
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async throws -> ADBAPKInstallReport {
#if canImport(Network) && canImport(Security)
        return try await ADBTVOperationTimeoutPolicy.apkInstallation.run(operation: .apkInstallation) {
            var connection = try await connectedDevice(for: device)
            defer { connection.cancel() }
            return try await ADBTVInstallOperation().installSelectedPackage(
                from: installModel,
                using: &connection,
                eventHandler: eventHandler
            )
        }
#else
        throw ADBTVInstallOperationError.unsupportedPlatform
#endif
    }

    @MainActor
    private func completeInstall(_ completion: InstallCompletion) {
        installTask = nil
        switch completion {
        case .success(let report):
            model.finishInstall(result: report.result)
        case .failure(let userMessage, let diagnosticDetail):
            model.failInstall(userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        }
    }

    private static func installDiagnosticDetail(_ error: Error, device: ADBTVDeviceSummary) -> DiagnosticDetail {
        var context = [
            "device": device.connectionDescription,
            "operation": "installAPK"
        ]
        if error is ADBAPKValidationError {
            context["phase"] = "validatePackage"
        }
        context = operationDiagnosticContext(error: error, base: context)

        return DiagnosticDetail(
            summary: String(describing: error),
            context: context
        )
    }

    private static func installUserMessage(for error: Error) -> String {
        if error is ADBTVOperationTimeoutError {
            return "APK installation timed out."
        }
        if error is ADBAPKValidationError {
            return "The selected file is not a valid APK."
        }

        return "Could not install APK."
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
                    userMessage: Self.remoteUserMessage(for: error),
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

    private func sendRemoteText(to device: ADBTVDeviceSummary) {
        guard let text = model.remoteText else {
            return
        }

        let remoteModel = model
        model.recordRemoteTextStarted()

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
                completeRemoteAction(completion)
            }
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
            let output = try await connection.runShellCommand(
                try ADBShellCommand("getprop ro.product.model")
            )
            let model = output.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func verifyPairedDevice(
        _ device: ADBTVDeviceSummary
    ) async throws -> ADBTVDeviceSummary {
        throw ADBTVManualDeviceError.unsupportedPlatform
    }
#endif

    @MainActor
    private func completeRemoteAction(_ completion: RemoteCompletion) {
        switch completion {
        case .success(let action):
            model.finishRemoteAction(action)
        case .textSuccess:
            model.finishRemoteText()
        case .failure(let action, let userMessage, let diagnosticDetail):
            model.failRemoteAction(action, userMessage: userMessage, diagnosticDetail: diagnosticDetail)
        case .textFailure(let userMessage, let diagnosticDetail):
            model.failRemoteText(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
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
        error is ADBTVOperationTimeoutError
            ? "The TV did not respond in time."
            : "Could not send text."
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
}

private enum RemoteCompletion: Sendable {
    case success(ADBTVRemoteAction)
    case textSuccess
    case failure(action: ADBTVRemoteAction, userMessage: String, diagnosticDetail: DiagnosticDetail)
    case textFailure(userMessage: String, diagnosticDetail: DiagnosticDetail)
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
                    userMessage: manualConnectionUserMessage(for: error),
                    diagnosticDetail: DiagnosticDetail(
                        summary: String(describing: error),
                        context: manualConnectionDiagnosticContext(
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

    private func manualConnectionUserMessage(for error: Error) -> String {
        error is ADBTVOperationTimeoutError
            ? "The TV did not respond in time."
            : "Could not connect to this Android TV device."
    }

    private func manualConnectionDiagnosticContext(
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
        case .failed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 6) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
#if os(iOS)
                if diagnosticDetail.context["reason"] == ADBBonjourDiscoveryFailure.Reason.noAuthorization.rawValue
                    || diagnosticDetail.context["reason"] == ADBBonjourDiscoveryFailure.Reason.localNetworkDenied.rawValue {
                    Button {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                }
#endif
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
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
    var remoteTextString: Binding<String>
    var canInstall: Bool
    var canSendRemoteText: Bool
    var chooseAPK: () -> Void
    var install: () -> Void
    var cancelInstall: () -> Void
    var sendRemoteAction: (ADBTVRemoteAction) -> Void
    var sendRemoteText: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DeviceHeader(device: device)
                APKInstallPanel(
                    installDraft: installDraft,
                    installURLString: installURLString,
                    canInstall: canInstall,
                    chooseAPK: chooseAPK,
                    install: install,
                    cancelInstall: cancelInstall
                )
                RemoteActionsPanel(
                    status: remoteStatus,
                    text: remoteTextString,
                    canSendText: canSendRemoteText,
                    send: sendRemoteAction,
                    sendText: sendRemoteText
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
    var cancelInstall: () -> Void

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
                .disabled(installDraft.status.isRunning)

                Button {
                    install()
                } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInstall || installDraft.status.isRunning)

                if installDraft.status.isRunning {
                    Button(role: .cancel) {
                        cancelInstall()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }

            TextField("https://example.com/app.apk", text: installURLString)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(installDraft.status.isRunning)

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
        case .transferring(let sentByteCount, let totalByteCount):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: transferFraction(sentByteCount, totalByteCount))
                Label("Transferring APK", systemImage: "arrow.up.doc")
                    .foregroundStyle(.secondary)
                Text("\(sentByteCount) of \(totalByteCount) bytes")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Label("Installation cancelled", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
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
        guard totalByteCount > 0 else {
            return 1
        }

        return min(max(Double(sentByteCount) / Double(totalByteCount), 0), 1)
    }
}

private struct RemoteActionsPanel: View {
    var status: ADBTVRemoteStatus
    var text: Binding<String>
    var canSendText: Bool
    var send: (ADBTVRemoteAction) -> Void
    var sendText: () -> Void

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
                Button {
                    send(.menu)
                } label: {
                    Label("Menu", systemImage: "line.3.horizontal")
                }
            }
            .buttonStyle(.bordered)
            .disabled(status.isSending)

            HStack(spacing: 8) {
                Button {
                    send(.volumeDown)
                } label: {
                    Label("Volume Down", systemImage: "speaker.minus")
                        .labelStyle(.iconOnly)
                }
                Button {
                    send(.volumeUp)
                } label: {
                    Label("Volume Up", systemImage: "speaker.plus")
                        .labelStyle(.iconOnly)
                }
                Button {
                    send(.power)
                } label: {
                    Label("Power", systemImage: "power")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.bordered)
            .disabled(status.isSending)

            HStack(spacing: 8) {
                TextField("Text", text: text)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button {
                    sendText()
                } label: {
                    Label("Send Text", systemImage: "paperplane")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSendText)
            }

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
        case .sendingText:
            Label("Sending text", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
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
            Text(diagnosticDetail.formattedDescription)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
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
