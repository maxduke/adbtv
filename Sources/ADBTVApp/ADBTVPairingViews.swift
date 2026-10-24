import ADBClientCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PairDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, host, connectionPort, pairingPort, code
    }

    @Binding var draft: ADBTVPairingDraft
    var status: ADBTVPairingStatus
    var startPairing: () -> Void
    var cancelPairing: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ADBTVFormField(adbTVLocalized("Name (Optional)")) {
                        TextField(adbTVLocalized("Device Name"), text: $draft.displayName)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = draft.pairingQRCode != nil
                                    ? nil : draft.discoveredService == nil ? .host : .code
                            }
                    }
                    if let qrCode = draft.pairingQRCode {
                        ADBTVLabeledValue(adbTVLocalized("Service"), value: qrCode.serviceName)
                    } else if let service = draft.discoveredService {
                        ADBTVLabeledValue(adbTVLocalized("Service"), value: service.displayName)
                    } else {
                        ADBTVFormField(adbTVLocalized("Host or IP Address")) {
                            TextField(adbTVLocalized("192.168.1.50 or tv.local"), text: $draft.host)
                                .adbTVAddressInput()
                                .focused($focusedField, equals: .host)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .connectionPort }
                        }
                        ADBTVFormField(adbTVLocalized("Connection Port")) {
                            TextField(adbTVLocalized("Port on the Wireless debugging screen"), text: $draft.connectionPortString)
                                .adbTVNumericInput()
                                .focused($focusedField, equals: .connectionPort)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .pairingPort }
                        }
                    }
                } header: {
                    Text(adbTVLocalized("Device"))
                } footer: {
                    if draft.discoveredService == nil && draft.pairingQRCode == nil {
                        Text(adbTVLocalized("On your TV, open Developer options → Wireless debugging. Use the IP address and connection port on that main screen."))
                    }
                }

                if draft.pairingQRCode == nil {
                    Section {
                        if draft.discoveredService == nil {
                            ADBTVFormField(adbTVLocalized("Pairing Port")) {
                                TextField(adbTVLocalized("Port in the pairing dialog"), text: $draft.pairingPortString)
                                    .adbTVNumericInput()
                                    .focused($focusedField, equals: .pairingPort)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .code }
                            }
                        }
                        ADBTVFormField(adbTVLocalized("Pairing Code")) {
                            TextField(adbTVLocalized("6-Digit Code"), text: $draft.codeString)
                                .adbTVNumericInput()
                                .focused($focusedField, equals: .code)
                                .submitLabel(.done)
                                .onSubmit {
                                    if draft.canStartPairing && !status.isPairing && !hasPaired {
                                        focusedField = nil
                                        startPairing()
                                    }
                                }
                        }
                    } header: {
                        Text(adbTVLocalized("Pairing"))
                    } footer: {
                        if draft.discoveredService == nil {
                            Text(adbTVLocalized("Choose Pair device with pairing code on your TV. Enter the code and pairing port from that dialog; its port differs from the connection port."))
                        } else {
                            Text(adbTVLocalized("Keep the pairing dialog open on your TV and enter its 6-digit code."))
                        }
                    }
                }

                PairingStatusView(status: status)
            }
            .disabled(status.isPairing || hasPaired)
            .navigationTitle(adbTVLocalized("Pair Device"))
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
                    Button(hasPaired ? adbTVLocalized("Done") : adbTVLocalized("Cancel")) {
                        cancelPairing()
                        dismiss()
                    }
                }

                if !hasPaired && draft.pairingQRCode == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(adbTVLocalized("Pair")) {
                            focusedField = nil
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
                    Text(adbTVLocalized("Finding the pairing service"))
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
                    Text(adbTVLocalized("Pairing with %@", String(describing: target)))
                        .foregroundStyle(.secondary)
                }
            }
        case .waitingForConnection(let deviceGUID, _):
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(adbTVLocalized("Finding the connection service"))
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
                    Text(adbTVLocalized("Verifying the TV connection"))
                        .foregroundStyle(.secondary)
                }
                Text(device.localizedConnectionDescription)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .paired(let device):
            Section {
                Label(adbTVLocalized("Paired with %@", String(describing: device.displayName)), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(adbTVLocalized("Saved as %@", device.localizedConnectionDescription))
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

struct DiscoveryContent: View {
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
                    status.isBrowsing ? adbTVLocalized("Stop Discovery") : adbTVLocalized("Discover Devices"),
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

    private var foundServicesTitle: String {
        serviceCount == 1 ? adbTVLocalized("1 service found")
            : adbTVLocalized("%@ services found", serviceCount.formatted())
    }

    var body: some View {
        switch status {
        case .idle:
            if serviceCount == 0 {
                EmptyView()
            } else {
                Label(foundServicesTitle, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .browsing:
            HStack(spacing: 8) {
                ProgressView()
                Text(serviceCount == 0 ? adbTVLocalized("Searching local network") : foundServicesTitle)
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
            Label(adbTVLocalized("Open Settings"), systemImage: "gear")
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
                    .accessibilityLabel(adbTVLocalized("Pair"))
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let kind = service.kind.map { adbTVLocalized($0.displayName) } ?? service.serviceType
        if let interfaceName = service.interfaceName, !interfaceName.isEmpty {
            return adbTVLocalized("%@ on %@", kind, interfaceName)
        }

        return kind
    }
}
