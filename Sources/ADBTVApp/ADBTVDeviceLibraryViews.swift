import ADBClientCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private func connectionUserMessage(for error: Error, fallback: String) -> String {
    error is ADBTVOperationTimeoutError
        ? adbTVLocalized("The TV did not respond in time.")
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

struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, host, port
    }

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
                Section {
                    ADBTVFormField(adbTVLocalized("Name (Optional)")) {
                        TextField(adbTVLocalized("Device Name"), text: $displayName)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .host }
                    }
                    ADBTVFormField(adbTVLocalized("Host or IP Address")) {
                        TextField(adbTVLocalized("192.168.1.50 or tv.local"), text: $host)
                            .adbTVAddressInput()
                            .focused($focusedField, equals: .host)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .port }
                    }
                    ADBTVFormField(adbTVLocalized("Connection Port")) {
                        TextField("5555", text: $port)
                            .adbTVNumericInput()
                            .focused($focusedField, equals: .port)
                            .submitLabel(.done)
                            .onSubmit { connectAndSave() }
                    }
                } header: {
                    Text(adbTVLocalized("Device"))
                } footer: {
                    Text(adbTVLocalized("Use the address and port shown by your TV's network ADB settings. Verified connections are saved. For Wireless debugging, use Pair with Code first."))
                }
                .disabled(status.isConnecting || status.isConnected)

                ManualDeviceConnectionStatusView(status: status)
            }
            .navigationTitle(adbTVLocalized("Add Device"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(adbTVLocalized("Done")) { focusedField = nil }
                }
#endif
                ToolbarItem(placement: .cancellationAction) {
                    Button(status.isConnected ? adbTVLocalized("Close") : adbTVLocalized("Cancel")) {
                        connectionTask?.cancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if !status.isConnected {
                        Button(adbTVLocalized("Connect")) {
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
              UInt16(exactly: portValue) != nil, portValue > 0 else {
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
        guard !status.isConnecting, !status.isConnected, let device = validatedDevice else {
            return
        }

        focusedField = nil
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
                        fallback: adbTVLocalized("Could not connect to this Android TV device.")
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
                    Text(adbTVLocalized("Connecting"))
                        .foregroundStyle(.secondary)
                }
            }
        case .connected(let device):
            Section {
                Label(adbTVLocalized("Connected and saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                LabeledContent(adbTVLocalized("Device"), value: device.model ?? device.displayName)
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

struct DeviceRow: View {
    var device: ADBTVDeviceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(device.displayName)
                .font(.headline)
            Text(device.localizedConnectionDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

enum ADBTVSavedDeviceConnectionState: Equatable {
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

struct SavedDeviceConnectionView: View {
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
                        Text(adbTVLocalized("Connecting and verifying"))
                            .foregroundStyle(.secondary)
                    }
                case .failed(_, let diagnosticDetail):
                    VStack(alignment: .leading, spacing: 12) {
                        Label(
                            adbTVLocalized("Could not connect to this TV."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)

                        Button(action: retry) {
                            Label(adbTVLocalized("Retry Connection"), systemImage: "arrow.clockwise")
                        }
                        .adbTVProminentButton()

                        Button(action: repair) {
                            Label(adbTVLocalized("Update Connection"), systemImage: "network")
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

struct RenameDeviceView: View {
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
                Section(adbTVLocalized("Device Name")) {
                    TextField(adbTVLocalized("Name"), text: $displayName, axis: .vertical)
                        .lineLimit(1...4)
                }

                if let saveError {
                    Section {
                        Label(adbTVLocalized("Could not rename this device."), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        DiagnosticDisclosure(diagnosticDetail: saveError)
                    }
                }
            }
            .navigationTitle(adbTVLocalized("Rename Device"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(adbTVLocalized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(adbTVLocalized("Save")) { save() }
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

struct RepairDeviceConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host, port
    }

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
                Section(adbTVLocalized("Saved Device")) {
                    ADBTVLabeledValue(adbTVLocalized("Name"), value: device.displayName)
                    ADBTVLabeledValue(adbTVLocalized("Current Connection"), value: device.localizedConnectionDescription)
                    if let model = device.model {
                        ADBTVLabeledValue(adbTVLocalized("Expected Model"), value: model)
                    }
                }

                Section(adbTVLocalized("New Connection")) {
                    ADBTVFormField(adbTVLocalized("Host or IP Address")) {
                        TextField(adbTVLocalized("192.168.1.50 or tv.local"), text: $host)
                            .adbTVAddressInput()
                            .focused($focusedField, equals: .host)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .port }
                    }
                    ADBTVFormField(adbTVLocalized("Connection Port")) {
                        TextField(adbTVLocalized("Port on your TV"), text: $port)
                            .adbTVNumericInput()
                            .focused($focusedField, equals: .port)
                            .submitLabel(.done)
                            .onSubmit { testConnection() }
                    }
                }
                .disabled(status.isVerifying)

                if status.verifiedDevice == nil {
                    Section {
                        Button {
                            testConnection()
                        } label: {
                            Label(adbTVLocalized("Test Connection"), systemImage: "network")
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
            .navigationTitle(adbTVLocalized("Update Connection"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(adbTVLocalized("Done")) { focusedField = nil }
                }
#endif
                ToolbarItem(placement: .cancellationAction) {
                    Button(adbTVLocalized("Cancel")) {
                        verificationTask?.cancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if let verifiedDevice = status.verifiedDevice {
                        Button(adbTVLocalized("Save")) {
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
            adbTVLocalized("This looks like a different TV"),
            isPresented: $confirmsDifferentModel,
            presenting: status.verifiedDevice
        ) { verifiedDevice in
            Button(adbTVLocalized("Use This Connection"), role: .destructive) {
                save(verifiedDevice)
            }
            Button(adbTVLocalized("Cancel"), role: .cancel) {}
        } message: { verifiedDevice in
            Text(
                adbTVLocalized("The saved model is %@, but this endpoint reports %@.", device.model ?? adbTVLocalized("Unknown"), verifiedDevice.model ?? adbTVLocalized("Unknown"))
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
        guard !status.isVerifying, status.verifiedDevice == nil, let candidateDevice else {
            return
        }

        focusedField = nil
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
                        fallback: adbTVLocalized("Could not verify this connection.")
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
            return adbTVLocalized("This connection is already saved as %@.", String(describing: displayName))
        }
        return adbTVLocalized("Could not save the updated connection.")
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
                    Text(adbTVLocalized("Testing connection"))
                        .foregroundStyle(.secondary)
                }
            }
        case .verified(let device):
            Section(adbTVLocalized("Verified Device")) {
                Label(adbTVLocalized("Connection verified"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                LabeledContent(adbTVLocalized("Detected Model"), value: device.model ?? adbTVLocalized("Unknown"))
                LabeledContent(adbTVLocalized("Connection"), value: device.localizedConnectionDescription)
                if warnsAboutDifferentModel {
                    Label(
                        adbTVLocalized("The detected model differs from the saved device."),
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
