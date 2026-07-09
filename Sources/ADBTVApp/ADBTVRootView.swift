import ADBClientCore
import SwiftUI
import UniformTypeIdentifiers

public struct ADBTVRootView: View {
    private let deviceStore: ADBTVDeviceStore

    @State private var model: ADBTVAppModel
    @State private var isFileImporterPresented = false
    @State private var isAddDevicePresented = false
    @State private var devicePersistenceError: DiagnosticDetail?
    @State private var installTask: Task<Void, Never>?

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
            }
            .navigationTitle("ADB TV")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddDevicePresented = true
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
                    canInstall: model.canInstallSelectedPackage,
                    chooseAPK: {
                        isFileImporterPresented = true
                    },
                    install: {
                        startInstall(for: device)
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
        guard let port = UInt16(exactly: device.port) else {
            throw ADBTVInstallOperationError.invalidDevicePort(device.port)
        }

        let endpoint = ADBNetworkEndpoint(host: device.host, port: port)
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
                "device": "\(device.host):\(device.port)",
                "operation": "installAPK"
            ]
        )
    }
}

private enum InstallCompletion: Sendable {
    case success(ADBAPKInstallReport)
    case failure(userMessage: String, diagnosticDetail: DiagnosticDetail)
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

private struct DeviceRow: View {
    var device: ADBTVDeviceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(device.displayName)
                .font(.headline)
            Text("\(device.host):\(device.port)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct DeviceDetailView: View {
    var device: ADBTVDeviceSummary
    var installDraft: ADBTVInstallDraft
    var canInstall: Bool
    var chooseAPK: () -> Void
    var install: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DeviceHeader(device: device)
                APKInstallPanel(
                    installDraft: installDraft,
                    canInstall: canInstall,
                    chooseAPK: chooseAPK,
                    install: install
                )
                RemoteActionsPanel()
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
            Text("\(device.host):\(device.port)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct APKInstallPanel: View {
    var installDraft: ADBTVInstallDraft
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

            if let package = installDraft.selectedPackage {
                LabeledContent("Package", value: package.fileName)
                if let byteCount = package.byteCount {
                    LabeledContent("Size", value: "\(byteCount) bytes")
                }
                if let fileURL = package.fileURL {
                    LabeledContent("Source", value: fileURL.lastPathComponent)
                }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote")
                .font(.title2.bold())

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Spacer()
                    Button {
                    } label: {
                        Label("Up", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    Spacer()
                }
                GridRow {
                    Button {
                    } label: {
                        Label("Left", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    Button {
                    } label: {
                        Text("OK")
                            .frame(minWidth: 44)
                    }
                    Button {
                    } label: {
                        Label("Right", systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                    }
                }
                GridRow {
                    Spacer()
                    Button {
                    } label: {
                        Label("Down", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                } label: {
                    Label("Back", systemImage: "arrow.uturn.backward")
                }
                Button {
                } label: {
                    Label("Home", systemImage: "house")
                }
                Button {
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .buttonStyle(.bordered)
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
