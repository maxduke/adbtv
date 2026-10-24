import ADBClientCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DeviceDetailView: View {
    var device: ADBTVDeviceSummary
    var installDraft: ADBTVInstallDraft
    var installURLString: Binding<String>
    var remoteStatus: ADBTVRemoteStatus
    var remoteTextString: Binding<String>
    var canInstall: Bool
    var canSendRemoteText: Bool
    var deviceOperationInProgress: Bool
    var installedAppReadOnlyRefreshInProgress: Bool
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
    var selectAppsMode: (ADBTVAppsMode) -> Void
    var retryInstalledAppDetails: () -> Void
    var loadActiveSystemSnapshot: (Int) -> Void
    var launchInstalledApp: (ADBTVInstalledPackage) -> Void
    var loadQuickLaunchUser: () async throws -> Int
    var loadQuickLaunchDetails: ADBTVQuickLaunchIcons.Loader
    var launchQuickApp: (ADBTVInstalledPackage, Int) async throws -> Void
    var forceStopInstalledApp: (ADBTVInstalledPackage) -> Void
    var uninstallInstalledApp: (ADBTVInstalledPackage) -> Void
    var openInstalledAppSettings: (ADBTVInstalledPackage) -> Void
    var clearInstalledAppData: (ADBTVInstalledPackage) -> Void
    var disableSystemApp: (ADBTVInstalledPackage, Int) -> Void
    var restoreSystemAppDefault: (ADBTVInstalledPackage, Int) -> Void
    var cancelInstalledAppOperation: () -> Void
    var cancelActivityRefresh: () -> Void
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

                Picker(adbTVLocalized("Device Tool"), selection: $selectedTool) {
                    ForEach(DeviceTool.allCases) { tool in
                        Text(tool.title).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(
                    deviceOperationInProgress
                        && !installedAppReadOnlyRefreshInProgress
                )

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
        .navigationBarBackButtonHidden(
            deviceOperationInProgress
                && !installedAppReadOnlyRefreshInProgress
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
#endif
        .onChange(of: selectedTool) { oldValue, newValue in
            if oldValue == .apps, newValue != .apps {
                cancelActivityRefresh()
            }
        }
        .onDisappear(perform: cancelActivityRefresh)
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
        ) {
            ADBTVQuickLaunchView(
                deviceID: device.id,
                deviceOperationInProgress: deviceOperationInProgress,
                detailsUserID: installedAppsState.userID,
                details: installedAppsState.displayedDetails,
                loadUser: loadQuickLaunchUser,
                loadDetails: loadQuickLaunchDetails,
                launch: launchQuickApp,
                chooseApps: { selectedTool = .apps }
            )
        }
    }

    private var appsPanel: some View {
        InstalledAppsPanel(
            state: installedAppsState,
            deviceOperationInProgress: deviceOperationInProgress,
            showInstaller: { isInstallerPresented = true },
            selectMode: selectAppsMode,
            retryDetails: retryInstalledAppDetails,
            installHelper: {
                isInstallerPresented = true
                installUnicodeInputHelper()
            },
            launch: launchInstalledApp,
            forceStop: forceStopInstalledApp,
            uninstall: uninstallInstalledApp,
            openSettings: openInstalledAppSettings,
            clearData: clearInstalledAppData,
            disableSystemApp: disableSystemApp,
            restoreSystemAppDefault: restoreSystemAppDefault,
            loadActiveSystemSnapshot: loadActiveSystemSnapshot,
            cancel: cancelInstalledAppOperation
        )
        .onChange(of: installDraft.status) { _, status in
            if status == .succeeded {
                selectAppsMode(.user)
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
        .navigationTitle(adbTVLocalized("Install App"))
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
            return adbTVLocalized("Remote")
        case .apps:
            return adbTVLocalized("Apps")
        case .tools:
            return adbTVLocalized("Tools")
        }
    }

}

struct DeviceHeader: View {
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
            Text(device.localizedConnectionDescription)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(action: repair) {
                Label(adbTVLocalized("Update Connection"), systemImage: "network")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(actionsDisabled)
            .help(adbTVLocalized("Update Connection"))

            Button(action: rename) {
                Label(adbTVLocalized("Rename Device"), systemImage: "pencil")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(actionsDisabled)
            .help(adbTVLocalized("Rename Device"))
        }
    }
}
