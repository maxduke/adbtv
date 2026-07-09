import ADBClientCore
import SwiftUI
import UniformTypeIdentifiers

public struct ADBTVRootView: View {
    @State private var model: ADBTVAppModel
    @State private var isFileImporterPresented = false

    public init(model: ADBTVAppModel = ADBTVAppModel()) {
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
                    }
                }
            }
            .navigationTitle("ADB TV")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
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
                        model.recordInstallEvent(.phaseStarted(.validatePackage))
                    }
                )
            } else {
                ContentUnavailableView("Select a Device", systemImage: "tv.and.hifispeaker.fill")
            }
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
