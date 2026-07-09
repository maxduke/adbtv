import ADBClientCore
import SwiftUI

public struct ADBTVRootView: View {
    @State private var model: ADBTVAppModel

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
                DeviceDetailView(device: device, installDraft: model.installDraft)
            } else {
                ContentUnavailableView("Select a Device", systemImage: "tv.and.hifispeaker.fill")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DeviceHeader(device: device)
                APKInstallPanel(installDraft: installDraft)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("APK Install")
                .font(.title2.bold())

            HStack(spacing: 12) {
                Button {
                } label: {
                    Label("Choose APK", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                } label: {
                    Label("Install", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!installDraft.canBuildInstallPlan)
            }

            if let package = installDraft.selectedPackage {
                LabeledContent("Package", value: package.fileName)
                if let byteCount = package.byteCount {
                    LabeledContent("Size", value: "\(byteCount) bytes")
                }
            }
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
