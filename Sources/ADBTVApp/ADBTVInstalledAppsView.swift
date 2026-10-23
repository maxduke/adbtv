import ADBClientCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private extension ADBTVAppsMode {
    var emptyTitle: String {
        switch self {
        case .user:
            return adbTVLocalized("No User Apps")
        case .system:
            return adbTVLocalized("No System Apps")
        case .active:
            return adbTVLocalized("No Active Apps")
        }
    }
}

struct InstalledAppsPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var state: ADBTVInstalledAppsViewState
    var deviceOperationInProgress: Bool
    var showInstaller: () -> Void
    var selectMode: (ADBTVAppsMode) -> Void
    var retryDetails: () -> Void
    var installHelper: () -> Void
    var launch: (ADBTVInstalledPackage) -> Void
    var forceStop: (ADBTVInstalledPackage) -> Void
    var uninstall: (ADBTVInstalledPackage) -> Void
    var openSettings: (ADBTVInstalledPackage) -> Void
    var clearData: (ADBTVInstalledPackage) -> Void
    var disableSystemApp: (ADBTVInstalledPackage, Int) -> Void
    var restoreSystemAppDefault: (ADBTVInstalledPackage, Int) -> Void
    var loadActiveSystemSnapshot: (Int) -> Void
    var cancel: () -> Void

    @State private var searchText = ProcessInfo.processInfo.arguments.contains("--ui-apps-no-matches")
        ? "unmatched app" : ""
    @State private var pendingForceStop: ADBTVInstalledPackage?
    @State private var pendingUninstall: ADBTVInstalledPackage?
    @State private var pinnedApps: [ADBTVPinnedApp] = []
    @State private var pinFailure: DiagnosticDetail?
    @State private var selectedPackage: ADBTVInstalledPackage? =
        ProcessInfo.processInfo.arguments.contains("--ui-app-details")
            || ProcessInfo.processInfo.arguments.contains("--ui-user-app-details")
            ? (try? ADBTVInstalledPackage(
                packageName: ProcessInfo.processInfo.arguments.contains("--ui-active")
                    ? "com.google.android.youtube.tv"
                    : "com.netflix.ninja"
            ))
            : nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(adbTVLocalized("Apps"))
                    .font(.title2.bold())
                Spacer()
                Menu {
                    Button(action: showInstaller) {
                        Label(adbTVLocalized("Install Package"), systemImage: "square.and.arrow.down")
                    }
                    Button(action: installHelper) {
                        Label(adbTVLocalized("Install Android Helper"), systemImage: "arrow.down.app")
                    }
                } label: {
                    Label(adbTVLocalized("Add App"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(deviceOperationInProgress || state.status.isBusy)
                .help(adbTVLocalized("Add App"))
                Button { selectMode(state.mode) } label: {
                    Label(adbTVLocalized("Refresh Apps"), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(deviceOperationInProgress || state.status.isBusy)
                .help(adbTVLocalized("Refresh Apps"))
            }

            Picker(adbTVLocalized("App View"), selection: Binding(
                get: { state.mode },
                set: selectMode
            )) {
                ForEach(ADBTVAppsMode.allCases) { mode in
                    Text(mode.title)
                        .accessibilityLabel(mode.accessibilityTitle)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(
                (deviceOperationInProgress || state.status.isBusy)
                    && !state.status.isActivityRefresh
            )

            TextField(adbTVLocalized("Search apps or packages"), text: $searchText)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif

            statusContent
            activitySnapshotStatus
            detailsLoadingStatus

            if !filteredPackages.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPackages) { package in
                        installedAppRow(
                            package,
                            details: displayedDetails[package.packageName],
                            activity: activeApp(for: package)
                        )
                        Divider()
                    }
                }
            } else if let emptyState = state.emptyState(matching: searchText) {
                ContentUnavailableView(
                    emptyState == .noApps ? state.mode.emptyTitle : adbTVLocalized("No Matching Apps"),
                    systemImage: emptyState == .noApps ? "square.grid.2x2" : "magnifyingglass"
                )
            } else if !state.hasSnapshot, case .ready = state.status {
                Button(adbTVLocalized("Load Apps")) { selectMode(state.mode) }
                    .buttonStyle(.bordered)
                    .disabled(deviceOperationInProgress)
            }
        }
        .onAppear {
            if state.status == .idle {
                selectMode(state.mode)
            }
        }
        .task(id: "\(state.deviceID?.uuidString ?? "none")/\(state.userID.map(String.init) ?? "none")") {
            loadPinnedApps()
        }
        .alert(adbTVLocalized("Quick Launch"), isPresented: Binding(
            get: { pinFailure != nil },
            set: { if !$0 { pinFailure = nil } }
        ), presenting: pinFailure) { _ in
            Button(adbTVLocalized("OK"), role: .cancel) {}
        } message: { failure in
            Text(failure.summary)
        }
        .onChange(of: state.mode) { _, _ in
            searchText = ""
            pendingForceStop = nil
            pendingUninstall = nil
            selectedPackage = nil
        }
        .confirmationDialog(
            adbTVLocalized("Force Stop App?"),
            isPresented: Binding(
                get: { pendingForceStop != nil },
                set: { if !$0 { pendingForceStop = nil } }
            ),
            presenting: pendingForceStop
        ) { package in
            Button(adbTVLocalized("Force Stop %@", String(describing: appTitle(for: package))), role: .destructive) {
                forceStop(package)
                pendingForceStop = nil
            }
        } message: { package in
            if appKind(for: package) == .system {
                Text(
                    adbTVLocalized("This is a system app. Stopping it may temporarily affect TV features, and Android may restart it.")
                )
            } else {
                Text(
                    adbTVLocalized("This stops the app, background activity, and playback without removing its data.")
                )
            }
        }
        .alert(
            pendingUninstall.map { adbTVLocalized("Uninstall %@?", String(describing: appTitle(for: $0))) } ?? adbTVLocalized("Uninstall App?"),
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            presenting: pendingUninstall
        ) { package in
            Button(adbTVLocalized("Uninstall"), role: .destructive) {
                uninstall(package)
                pendingUninstall = nil
            }
            Button(adbTVLocalized("Cancel"), role: .cancel) { pendingUninstall = nil }
        } message: { package in
            Text(adbTVLocalized("This removes %@ and its app data for the current TV user.\n\n%@", String(describing: appTitle(for: package)), String(describing: package.packageName)))
        }
        .sheet(item: $selectedPackage) { package in
            InstalledAppDetailsView(
                package: package,
                details: displayedDetails[package.packageName],
                activity: activeApp(for: package),
                activityCapturedAt: state.activitySnapshot?.capturedAt,
                systemSnapshot: systemSnapshot(for: package),
                systemControlStatus: state.status,
                actionsDisabled: deviceOperationInProgress || state.status.isBusy || state.userID == nil,
                appKind: appKind(for: package),
                launch: launch,
                forceStop: forceStop,
                uninstall: uninstall,
                openSettings: openSettings,
                clearData: clearData,
                disableSystemApp: disableSystemApp,
                restoreSystemAppDefault: restoreSystemAppDefault
            )
        }
    }

    @ViewBuilder
    private var detailsLoadingStatus: some View {
        switch state.detailsStatus {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text(adbTVLocalized("Loading app names and icons"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .helperUnavailable:
            Text(adbTVLocalized("Install the Android Helper to show app names and icons."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let failure):
            if state.userID != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label(adbTVLocalized("Some app names and icons could not be loaded."), systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                    Button(adbTVLocalized("Retry App Details"), action: retryDetails)
                        .disabled(deviceOperationInProgress || state.status.isBusy)
                    DiagnosticDisclosure(diagnosticDetail: DiagnosticDetail(
                        summary: failure,
                        context: ["operation": "loadInstalledAppDetails"]
                    ))
                }
            }
        case .idle:
            if !state.pendingDetailsPackages.isEmpty {
                Button(adbTVLocalized("Load App Names and Icons"), action: retryDetails)
                    .disabled(deviceOperationInProgress || state.status.isBusy || state.userID == nil)
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch state.status {
        case .idle:
            EmptyView()
        case .loading:
            progressLabel(adbTVLocalized("Loading installed apps"), cancel: cancel)
        case .loadingActivity:
            progressLabel(adbTVLocalized("Refreshing active apps"), cancel: cancel)
        case .loadingSystemControl:
            progressLabel(adbTVLocalized("Loading system controls"), cancel: cancel)
        case .launching(let package):
            progressLabel(adbTVLocalized("Launching %@", String(describing: appTitle(for: package))), cancel: cancel)
        case .stopping(let package):
            progressLabel(adbTVLocalized("Stopping %@", String(describing: appTitle(for: package))), cancel: cancel)
        case .uninstalling(let package):
            progressLabel(adbTVLocalized("Uninstalling %@", String(describing: appTitle(for: package))), cancel: cancel)
        case .openingSettings(let package):
            progressLabel(
                adbTVLocalized("Opening App Settings for %@", String(describing: appTitle(for: package))),
                cancel: cancel
            )
        case .clearingData(let package):
            progressLabel(adbTVLocalized("Clearing data for %@", String(describing: appTitle(for: package))), cancel: cancel)
        case .disabling(let package):
            progressLabel(adbTVLocalized("Disabling %@", String(describing: appTitle(for: package))), cancel: cancel)
        case .restoringDefault(let package):
            progressLabel(
                adbTVLocalized("Restoring %@ to Android default", String(describing: appTitle(for: package))),
                cancel: cancel
            )
        case .ready(let message):
            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        case .failed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 8) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button { selectMode(state.mode) } label: {
                    Label(adbTVLocalized("Reload Apps"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(deviceOperationInProgress)
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        }
    }

    @ViewBuilder
    private var activitySnapshotStatus: some View {
        if state.mode == .active, let snapshot = state.activitySnapshot {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text(adbTVLocalized("Updated"))
                    .foregroundStyle(.secondary)
                Text(snapshot.capturedAt, style: .relative)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)

            if snapshot.diagnostics.isPartial {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        adbTVLocalized("Some activity details are unavailable."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    DiagnosticDisclosure(
                        diagnosticDetail: DiagnosticDetail(
                            summary: "The app activity snapshot contains partial data.",
                            context: [
                                "invalidMemoryRows": String(
                                    snapshot.diagnostics.invalidMemoryRowCount
                                ),
                                "missingMemoryProcesses": String(
                                    snapshot.diagnostics.missingMemoryProcessCount
                                ),
                                "omittedProcesses": String(
                                    snapshot.diagnostics.omittedProcessCount
                                ),
                                "operation": "loadAppActivity",
                                "unresolvedForegroundApps": String(
                                    snapshot.diagnostics.unresolvedForegroundCount
                                )
                            ]
                        )
                    )
                }
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
                Label(adbTVLocalized("Cancel"), systemImage: "xmark")
            }
            .buttonStyle(.bordered)
        }
    }

    private func installedAppRow(
        _ package: ADBTVInstalledPackage,
        details: ADBTVInstalledAppDetails?,
        activity: ADBTVActiveApp?
    ) -> some View {
        HStack(spacing: 12) {
            Button {
                selectPackage(package)
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize, let activity {
                        VStack(alignment: .leading, spacing: 8) {
                            installedAppIdentity(
                                package,
                                details: details,
                                activity: activity
                            )
                            activityMemory(activity)
                        }
                    } else {
                        HStack(spacing: 12) {
                            installedAppIdentity(
                                package,
                                details: details,
                                activity: activity
                            )
                            if let activity {
                                activityMemory(activity)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rowAccessibilityLabel(
                package,
                details: details,
                activity: activity
            ))

            Menu {
                Button {
                    selectPackage(package)
                } label: {
                    Label(adbTVLocalized("Details"), systemImage: "info.circle")
                }

                let isPinned = pinnedApps.contains { $0.packageName == package.packageName }
                Button { togglePin(package) } label: {
                    Label(
                        isPinned ? adbTVLocalized("Remove from Quick Launch")
                            : pinnedApps.count >= ADBTVQuickLaunchStore.maximumAppCount
                                ? adbTVLocalized("Quick Launch Full (6)") : adbTVLocalized("Pin to Remote"),
                        systemImage: isPinned ? "pin.slash" : "pin"
                    )
                }
                .disabled(
                    deviceOperationInProgress || state.status.isBusy || state.userID == nil
                        || (!isPinned && pinnedApps.count >= ADBTVQuickLaunchStore.maximumAppCount)
                )

                Button {
                    launch(package)
                } label: {
                    Label(adbTVLocalized("Launch"), systemImage: "play.fill")
                }
                .disabled(
                    deviceOperationInProgress
                        || state.status.isBusy
                        || state.userID == nil
                        || (state.mode == .system && state.systemSnapshot == nil)
                        || systemState(for: package) == .disabled
                )

                if appKind(for: package) == .user || state.mode == .active {
                    Button(role: .destructive) {
                        pendingForceStop = package
                    } label: {
                        Label(
                            activity == nil && details?.isStopped == true
                                ? adbTVLocalized("Stopped") : adbTVLocalized("Force Stop"),
                            systemImage: activity == nil && details?.isStopped == true
                                ? "stop.circle.fill" : "stop.circle"
                        )
                    }
                    .disabled(
                        deviceOperationInProgress
                            || state.status.isBusy
                            || state.userID == nil
                            || (activity == nil && details?.isStopped == true)
                            || systemState(for: package) == .disabled
                    )
                }

                if appKind(for: package) == .user {
                    Divider()

                    Button(role: .destructive) {
                        pendingUninstall = package
                    } label: {
                        Label(adbTVLocalized("Uninstall"), systemImage: "trash")
                    }
                    .disabled(deviceOperationInProgress || state.status.isBusy || state.userID == nil)
                }
            } label: {
                Label(adbTVLocalized("Actions for %@", String(describing: package.packageName)), systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help(adbTVLocalized("App Actions"))
        }
        .padding(.vertical, 8)
    }

    private func installedAppIdentity(
        _ package: ADBTVInstalledPackage,
        details: ADBTVInstalledAppDetails?,
        activity: ADBTVActiveApp?
    ) -> some View {
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
                if let activity {
                    Text(activityStatus(activity))
                        .font(.caption)
                        .foregroundStyle(activity.isForeground ? .primary : .secondary)
                        .lineLimit(2)
                } else if systemState(for: package) == .disabled {
                    Label(adbTVLocalized("Disabled"), systemImage: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func activityMemory(_ activity: ADBTVActiveApp) -> some View {
        Text(activity.memoryByteCount.map(Self.formattedBytes) ?? adbTVLocalized("Unavailable"))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(activity.memoryByteCount == nil ? .secondary : .primary)
            .frame(
                maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                alignment: .leading
            )
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
    }

    private var displayedDetails: [String: ADBTVInstalledAppDetails] {
        state.displayedDetails
    }

    private func loadPinnedApps() {
        guard let deviceID = state.deviceID, let userID = state.userID else {
            pinnedApps = []
            return
        }
        do {
            pinnedApps = try ADBTVQuickLaunchStore().apps(deviceID: deviceID, userID: userID)
        } catch {
            pinnedApps = []
            pinFailure = DiagnosticDetail(summary: ADBTVQuickLaunchError.invalidArchive.userMessage)
        }
    }

    private func togglePin(_ package: ADBTVInstalledPackage) {
        guard let deviceID = state.deviceID, let userID = state.userID,
              !deviceOperationInProgress, !state.status.isBusy else { return }
        do {
            let store = ADBTVQuickLaunchStore()
            if pinnedApps.contains(where: { $0.packageName == package.packageName }) {
                pinnedApps = try store.remove(packageNames: [package.packageName], deviceID: deviceID, userID: userID)
            } else {
                pinnedApps = try store.pin(
                    package, displayName: displayedDetails[package.packageName]?.displayName,
                    deviceID: deviceID, userID: userID
                )
            }
        } catch {
            pinFailure = DiagnosticDetail(summary: (error as? ADBTVQuickLaunchError)?.userMessage
                ?? adbTVLocalized("Could not save Quick Launch apps."))
        }
    }

    private func activeApp(for package: ADBTVInstalledPackage) -> ADBTVActiveApp? {
        guard state.mode == .active else {
            return nil
        }
        return state.activitySnapshot?.apps.first { $0.package == package }
    }

    private func appKind(for package: ADBTVInstalledPackage) -> ADBTVInstalledAppKind {
        if let activity = activeApp(for: package) {
            return activity.kind
        }
        return state.mode == .system ? .system : .user
    }

    private func systemSnapshot(
        for package: ADBTVInstalledPackage
    ) -> ADBTVSystemAppSnapshot? {
        appKind(for: package) == .system
            ? (state.mode == .active ? state.activeSystemSnapshot : state.systemSnapshot)
            : nil
    }

    private func systemState(
        for package: ADBTVInstalledPackage
    ) -> ADBTVInstalledAppState {
        systemSnapshot(for: package)?.state(for: package) ?? .enabled
    }

    private func selectPackage(_ package: ADBTVInstalledPackage) {
        selectedPackage = package
        guard state.mode == .active,
              appKind(for: package) == .system,
              state.activeSystemSnapshot == nil,
              let userID = state.activitySnapshot?.userID,
              !state.status.isBusy else {
            return
        }
        loadActiveSystemSnapshot(userID)
    }

    private func activityStatus(_ activity: ADBTVActiveApp) -> String {
        let state = activity.isForeground ? adbTVLocalized("Foreground") : adbTVLocalized("Background")
        let kind = activity.kind == .user ? adbTVLocalized("User") : adbTVLocalized("System")
        let processes = activity.processCount == 1
            ? adbTVLocalized("1 process") : adbTVLocalized("%@ processes", activity.processCount.formatted())
        return "\(state) | \(kind) | \(processes)"
    }

    private func rowAccessibilityLabel(
        _ package: ADBTVInstalledPackage,
        details: ADBTVInstalledAppDetails?,
        activity: ADBTVActiveApp?
    ) -> String {
        var values = [adbTVLocalized("Show details for %@", String(describing: details?.displayName ?? package.packageName))]
        if let activity {
            values.append(activityStatus(activity))
            values.append(
                activity.memoryByteCount.map(Self.formattedBytes) ?? adbTVLocalized("Memory unavailable")
            )
        } else if systemState(for: package) == .disabled {
            values.append(adbTVLocalized("Disabled"))
        }
        return values.joined(separator: ", ")
    }

    private static func formattedBytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .memory)
    }

    private var filteredPackages: [ADBTVInstalledPackage] {
        state.filteredPackages(matching: searchText)
    }

    private func appTitle(for package: ADBTVInstalledPackage) -> String {
        displayedDetails[package.packageName]?.displayName ?? package.packageName
    }
}

private struct InstalledAppDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var package: ADBTVInstalledPackage
    var details: ADBTVInstalledAppDetails?
    var activity: ADBTVActiveApp?
    var activityCapturedAt: Date?
    var systemSnapshot: ADBTVSystemAppSnapshot?
    var systemControlStatus: ADBTVInstalledAppsStatus
    var actionsDisabled: Bool
    var appKind: ADBTVInstalledAppKind
    var launch: (ADBTVInstalledPackage) -> Void
    var forceStop: (ADBTVInstalledPackage) -> Void
    var uninstall: (ADBTVInstalledPackage) -> Void
    var openSettings: (ADBTVInstalledPackage) -> Void
    var clearData: (ADBTVInstalledPackage) -> Void
    var disableSystemApp: (ADBTVInstalledPackage, Int) -> Void
    var restoreSystemAppDefault: (ADBTVInstalledPackage, Int) -> Void

    @State private var confirmsForceStop = false
    @State private var confirmsUninstall = ProcessInfo.processInfo.arguments.contains("--ui-uninstall-confirm")
    @State private var confirmsClearData = ProcessInfo.processInfo.arguments.contains("--ui-clear-data-confirm")
    @State private var confirmsDisable = ProcessInfo.processInfo.arguments.contains("--ui-disable-confirm")
    @State private var confirmsRestoreDefault = ProcessInfo.processInfo.arguments.contains("--ui-restore-confirm")

    var body: some View {
        NavigationStack {
            List {
                Section(adbTVLocalized("Package Identifier")) {
                    VStack(alignment: .leading, spacing: 12) {
                        if dynamicTypeSize.isAccessibilitySize {
                            HStack {
                                InstalledAppIconView(icon: details?.icon)
                                Spacer()
                                copyPackageButton
                            }
                            if let displayName = details?.displayName {
                                Text(displayName)
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            HStack(alignment: .center, spacing: 12) {
                                InstalledAppIconView(icon: details?.icon)
                                if let displayName = details?.displayName {
                                    Text(displayName)
                                        .font(.headline)
                                        .lineLimit(3)
                                }
                                Spacer(minLength: 0)
                                copyPackageButton
                            }
                        }

                        Text(package.packageName)
                            .font(dynamicTypeSize.isAccessibilitySize ? .caption.monospaced() : .body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let activity {
                    Section(adbTVLocalized("Activity")) {
                        LabeledContent(
                            adbTVLocalized("Status"),
                            value: activity.isForeground ? adbTVLocalized("Foreground") : adbTVLocalized("Background")
                        )
                        LabeledContent(
                            adbTVLocalized("Memory"),
                            value: activity.memoryByteCount.map {
                                ByteCountFormatter.string(
                                    fromByteCount: $0,
                                    countStyle: .memory
                                )
                            } ?? adbTVLocalized("Unavailable")
                        )
                        LabeledContent(
                            adbTVLocalized("Processes"),
                            value: String(activity.processCount)
                        )
                        if let activityCapturedAt {
                            LabeledContent(adbTVLocalized("Updated")) {
                                Text(activityCapturedAt, style: .relative)
                            }
                        }
                    }
                }

                if hasMetadata {
                    Section(adbTVLocalized("Information")) {
                        if let versionName = details?.versionName {
                            LabeledContent(adbTVLocalized("Version"), value: versionName)
                        }
                        if let versionCode = details?.versionCode {
                            LabeledContent(adbTVLocalized("Version Code"), value: String(versionCode))
                        }
                        if let apkByteCount = details?.apkByteCount {
                            LabeledContent(
                                adbTVLocalized("APK Size"),
                                value: ByteCountFormatter.string(
                                    fromByteCount: apkByteCount,
                                    countStyle: .file
                                )
                            )
                        }
                        if let firstInstallDate = details?.firstInstallDate {
                            LabeledContent(adbTVLocalized("Installed")) {
                                Text(firstInstallDate, style: .date)
                            }
                        }
                        if let lastUpdateDate = details?.lastUpdateDate {
                            LabeledContent(adbTVLocalized("Updated")) {
                                Text(lastUpdateDate, style: .date)
                            }
                        }
                    }
                }

                if appKind == .system, systemSnapshot != nil {
                    systemControlSection
                } else if appKind == .system {
                    unavailableSystemControlSection
                }

                Section(adbTVLocalized("App Maintenance")) {
                    Button {
                        dismiss()
                        openSettings(package)
                    } label: {
                        Label(adbTVLocalized("Open App Settings on TV"), systemImage: "gearshape")
                    }
                    .disabled(actionsDisabled)

                    if appKind == .user {
                        Button(role: .destructive) {
                            confirmsClearData = true
                        } label: {
                            Label(adbTVLocalized("Clear App Data"), systemImage: "eraser")
                                .foregroundStyle(.red)
                        }
                        .disabled(actionsDisabled)
                    }
                }

                Section {
                    Button {
                        dismiss()
                        launch(package)
                    } label: {
                        Label(adbTVLocalized("Launch App"), systemImage: "play.fill")
                    }
                    .disabled(
                        actionsDisabled
                            || (activity == nil && appKind == .system && systemSnapshot == nil)
                            || systemState == .disabled
                    )

                    Button(role: .destructive) {
                        confirmsForceStop = true
                    } label: {
                        Label(
                            isStopped ? adbTVLocalized("Stopped") : adbTVLocalized("Force Stop"),
                            systemImage: isStopped
                                ? "stop.circle.fill" : "stop.circle"
                        )
                            .foregroundStyle(.red)
                    }
                    .disabled(
                        actionsDisabled
                            || (activity == nil && appKind == .system && systemSnapshot == nil)
                            || isStopped
                            || systemState == .disabled
                    )

                    if appKind == .user {
                        Button(role: .destructive) {
                            confirmsUninstall = true
                        } label: {
                            Label(adbTVLocalized("Uninstall App"), systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .disabled(actionsDisabled)
                    }
                }
            }
            .labeledContentStyle(ADBTVAdaptiveLabeledContentStyle())
            .navigationTitle(details?.displayName ?? adbTVLocalized("App Details"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(adbTVLocalized("Done")) {
                        dismiss()
                    }
                }
            }
            .alert(
                adbTVLocalized("Clear Data for %@?", appTitle),
                isPresented: $confirmsClearData
            ) {
                Button(adbTVLocalized("Clear"), role: .destructive) {
                    dismiss()
                    clearData(package)
                }
                Button(adbTVLocalized("Cancel"), role: .cancel) {}
            } message: {
                Text(
                    adbTVLocalized("Permanently deletes all app data. App stays installed.\n%@", String(describing: package.packageName))
                )
            }
            .alert(
                adbTVLocalized("Disable %@?", appTitle),
                isPresented: $confirmsDisable
            ) {
                Button(adbTVLocalized("Disable"), role: .destructive) {
                    guard let userID = systemSnapshot?.userID else {
                        return
                    }
                    dismiss()
                    disableSystemApp(package, userID)
                }
                Button(adbTVLocalized("Cancel"), role: .cancel) {}
            } message: {
                Text(
                    adbTVLocalized("May disrupt TV features or other apps. Keeps app and data.\n%@", String(describing: package.packageName))
                )
            }
            .alert(
                adbTVLocalized("Restore Default?"),
                isPresented: $confirmsRestoreDefault
            ) {
                Button(adbTVLocalized("Restore")) {
                    guard let userID = systemSnapshot?.userID else {
                        return
                    }
                    dismiss()
                    restoreSystemAppDefault(package, userID)
                }
                Button(adbTVLocalized("Cancel"), role: .cancel) {}
            } message: {
                Text(
                    adbTVLocalized("May undo a prior disable setting and re-enable this app.\n%@", String(describing: package.packageName))
                )
            }
            .confirmationDialog(
                adbTVLocalized("Force Stop App?"),
                isPresented: $confirmsForceStop
            ) {
                Button(adbTVLocalized("Force Stop"), role: .destructive) {
                    dismiss()
                    forceStop(package)
                }
            } message: {
                if appKind == .user {
                    Text(adbTVLocalized("This stops the app, background activity, and playback without removing its data."))
                } else {
                    Text(adbTVLocalized("This is a system app. Stopping it may temporarily affect TV features, and Android may restart it."))
                }
            }
            .alert(
                adbTVLocalized("Uninstall %@?", String(describing: appTitle)),
                isPresented: $confirmsUninstall
            ) {
                Button(adbTVLocalized("Uninstall"), role: .destructive) {
                    dismiss()
                    uninstall(package)
                }
                Button(adbTVLocalized("Cancel"), role: .cancel) {}
            } message: {
                Text(adbTVLocalized("This removes %@ and its app data for the current TV user.\n\n%@", String(describing: appTitle), String(describing: package.packageName)))
            }
        }
    }

    @ViewBuilder
    private var unavailableSystemControlSection: some View {
        Section(adbTVLocalized("System Control")) {
            switch systemControlStatus {
            case .loadingSystemControl:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(adbTVLocalized("Loading system controls"))
                        .foregroundStyle(.secondary)
                }
            case .failed(let userMessage, let diagnosticDetail):
                VStack(alignment: .leading, spacing: 8) {
                    Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
                }
            default:
                Label(
                    adbTVLocalized("System controls are unavailable for this snapshot."),
                    systemImage: "shield.slash"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private var copyPackageButton: some View {
        Button(action: copyPackageName) {
            Label(adbTVLocalized("Copy Package Identifier"), systemImage: "doc.on.doc")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(adbTVLocalized("Copy Package Identifier"))
    }

    @ViewBuilder
    private var systemControlSection: some View {
        Section(adbTVLocalized("System Control")) {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    systemState == .disabled ? adbTVLocalized("Disabled") : adbTVLocalized("Enabled"),
                    systemImage: systemState == .disabled
                        ? "pause.circle.fill" : "checkmark.circle.fill"
                )
                .foregroundStyle(systemState == .disabled ? Color.orange : Color.accentColor)

                if systemState == .disabled {
                    Text(adbTVLocalized("Restore Android's package default without removing app data."))
                        .foregroundStyle(.secondary)
                    Button {
                        confirmsRestoreDefault = true
                    } label: {
                        Label(
                            adbTVLocalized("Restore Android Default"),
                            systemImage: "arrow.uturn.backward.circle"
                        )
                    }
                    .disabled(actionsDisabled)
                } else if let protectionReason {
                    Label(protectionReason.explanation, systemImage: "lock.shield.fill")
                        .foregroundStyle(.secondary)
                } else if let failure = systemSnapshot?.safetyCheckFailureDescription {
                    Label(
                        adbTVLocalized("Disable is unavailable because safety checks failed."),
                        systemImage: "shield.slash"
                    )
                        .foregroundStyle(.orange)
                    DiagnosticDisclosure(
                        diagnosticDetail: DiagnosticDetail(
                            summary: failure,
                            context: ["operation": "loadSystemAppProtection"]
                        )
                    )
                } else {
                    Button(role: .destructive) {
                        confirmsDisable = true
                    } label: {
                        Label(adbTVLocalized("Disable System App"), systemImage: "pause.circle")
                            .foregroundStyle(.red)
                    }
                    .disabled(actionsDisabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var systemState: ADBTVInstalledAppState {
        systemSnapshot?.state(for: package) ?? .enabled
    }

    private var isStopped: Bool {
        activity == nil && details?.isStopped == true
    }

    private var protectionReason: ADBTVInstalledAppProtectionReason? {
        systemSnapshot?.protectionReason(for: package)
    }

    private var appTitle: String {
        details?.displayName ?? package.packageName
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

private extension ADBTVInstalledAppProtectionReason {
    var explanation: String {
        switch self {
        case .androidCore:
            return adbTVLocalized("Protected because Android requires this package.")
        case .ecosystemInfrastructure:
            return adbTVLocalized("Protected because core Google services require this package.")
        case .activeLauncher:
            return adbTVLocalized("Protected because this is the active TV launcher.")
        case .settings:
            return adbTVLocalized("Protected because this provides Android Settings.")
        case .activeInputMethod:
            return adbTVLocalized("Protected because this is the active input method.")
        }
    }
}

struct InstalledAppIconView: View {
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
