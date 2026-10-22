import ADBClientCore
import SwiftUI

@MainActor
struct ADBTVQuickLaunchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var deviceID: UUID
    var deviceOperationInProgress: Bool
    var detailsUserID: Int?
    var details: [String: ADBTVInstalledAppDetails]
    var loadUser: () async throws -> Int
    var launch: (ADBTVInstalledPackage, Int) async throws -> Void
    var chooseApps: () -> Void

    private let store = ADBTVQuickLaunchStore()
    @State private var userID: Int?
    @State private var apps: [ADBTVPinnedApp] = []
    @State private var isLoading = false
    @State private var refreshID = UUID()
    @State private var launchID: UUID?
    @State private var launchTask: Task<Void, Never>?
    @State private var launchingPackage: String?
    @State private var message: String?
    @State private var failure: DiagnosticDetail?
    @State private var isManagePresented = ProcessInfo.processInfo.arguments.contains("--ui-quick-manage")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(adbTVLocalized("Quick Launch"))
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: apps.isEmpty ? chooseApps : { isManagePresented = true }) {
                    Label(apps.isEmpty ? adbTVLocalized("Choose Apps") : adbTVLocalized("Manage"), systemImage: apps.isEmpty ? "plus" : "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(deviceOperationInProgress || isLoading || launchID != nil)
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(adbTVLocalized("Checking TV user"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if !apps.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(apps) { app in
                            Button { launchApp(app) } label: {
                                HStack(spacing: 8) {
                                    InstalledAppIconView(icon: detailsUserID == userID ? details[app.packageName]?.icon : nil)
                                    Text(app.title)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 240 : 180, alignment: .leading)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.bordered)
                            .disabled(deviceOperationInProgress || launchID != nil || userID == nil || scenePhase != .active)
                            .accessibilityLabel(adbTVLocalized("Launch %@", String(describing: app.title)))
                        }
                    }
                }
            }

            if let launchingPackage {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(adbTVLocalized("Launching %@", String(describing: launchingPackage)))
                        .font(.footnote)
                }
                Button(adbTVLocalized("Cancel")) { launchTask?.cancel() }
                    .buttonStyle(.bordered)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Button(adbTVLocalized("Refresh Quick Launch")) { refreshID = UUID() }
                    .disabled(deviceOperationInProgress || launchID != nil)
                DiagnosticDisclosure(diagnosticDetail: failure)
            }
        }
        .task(id: refreshID) { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshID = UUID()
            } else if phase == .background {
                cancelLaunch()
                userID = nil
                apps = []
                refreshID = UUID()
            }
        }
        .onDisappear(perform: cancelLaunch)
        .onChange(of: isManagePresented) { _, presented in
            guard presented, let userID, !usesPreviewData else { return }
            do {
                apps = try store.apps(deviceID: deviceID, userID: userID)
                failure = nil
                message = nil
            } catch {
                present(error, fallback: adbTVLocalized("Could not load pinned apps."))
            }
        }
        .sheet(isPresented: $isManagePresented) {
            ADBTVQuickLaunchManagementView(
                apps: apps,
                failureMessage: failure == nil ? nil : message,
                isBusy: isLoading || deviceOperationInProgress || launchID != nil,
                chooseApps: {
                    isManagePresented = false
                    chooseApps()
                },
                remove: remove,
                move: move
            )
        }
    }

    private func reload() async {
        guard scenePhase == .active, launchID == nil else { return }
        let request = refreshID
        userID = nil
        apps = []
        isLoading = false
        failure = nil
        message = nil
        if usesPreviewData {
            userID = 0
            if ProcessInfo.processInfo.arguments.contains("--ui-quick-launch") {
                apps = Self.previewApps
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-quick-failed") {
                message = adbTVLocalized("This app is no longer installed for this TV user. Remove it from Quick Launch or reinstall it.")
                failure = DiagnosticDetail(summary: "Preview package is not installed.")
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-quick-sent") {
                message = adbTVLocalized("Opened Netflix on the TV.")
            }
            return
        }
        guard store.hasSavedApps(deviceID: deviceID) else { return }
        isLoading = true
        defer { if request == refreshID { isLoading = false } }
        do {
            let currentUser = try await loadUser()
            try Task.checkCancellation()
            guard request == refreshID else { return }
            apps = try store.apps(deviceID: deviceID, userID: currentUser)
            userID = currentUser
        } catch {
            guard !Task.isCancelled, request == refreshID else { return }
            present(error, fallback: adbTVLocalized("Could not load Quick Launch. Check the TV connection and refresh."))
        }
    }

    private func launchApp(_ app: ADBTVPinnedApp) {
        guard let userID, launchID == nil, !deviceOperationInProgress,
              let package = try? ADBTVInstalledPackage(packageName: app.packageName) else { return }
        if usesPreviewData {
            message = adbTVLocalized("Opened %@ on the TV.", String(describing: app.title))
            return
        }
        let token = UUID()
        launchID = token
        launchingPackage = app.title
        failure = nil
        message = nil
        launchTask = Task { @MainActor in
            defer {
                if launchID == token {
                    launchID = nil
                    launchingPackage = nil
                    launchTask = nil
                }
            }
            do {
                try await launch(package, userID)
                try Task.checkCancellation()
                guard launchID == token else { return }
                message = adbTVLocalized("Opened %@ on the TV.", String(describing: app.title))
            } catch {
                guard !Task.isCancelled, launchID == token else { return }
                present(error, fallback: adbTVLocalized("Could not launch %@.", String(describing: app.title)))
                if let error = error as? ADBTVInstalledAppError, case .activeUserChanged = error {
                    self.userID = nil
                    apps = []
                }
            }
        }
    }

    private func cancelLaunch() {
        launchTask?.cancel()
        launchTask = nil
        launchID = nil
        launchingPackage = nil
    }

    private func remove(_ offsets: IndexSet) {
        guard let userID else { return }
        let names = Set(offsets.compactMap { apps.indices.contains($0) ? apps[$0].packageName : nil })
        if usesPreviewData {
            apps.removeAll { names.contains($0.packageName) }
            return
        }
        do {
            apps = try store.remove(packageNames: names, deviceID: deviceID, userID: userID)
            message = nil
            failure = nil
        } catch {
            present(error, fallback: adbTVLocalized("Could not update Quick Launch."))
        }
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        guard let userID else { return }
        var reordered = apps
        reordered.move(fromOffsets: offsets, toOffset: destination)
        if usesPreviewData {
            apps = reordered
            return
        }
        do {
            apps = try store.reorder(packageNames: reordered.map(\.packageName), deviceID: deviceID, userID: userID)
            message = nil
            failure = nil
        } catch {
            present(error, fallback: adbTVLocalized("Could not update Quick Launch."))
        }
    }

    private func present(_ error: Error, fallback: String) {
        if let error = error as? ADBTVQuickLaunchError {
            message = error.userMessage
        } else if let error = error as? ADBTVInstalledAppError {
            switch error {
            case .activeUserChanged:
                message = adbTVLocalized("The TV user changed. Refresh Quick Launch before trying again.")
            case .packageNotInstalled:
                message = adbTVLocalized("This app is no longer installed for this TV user. Remove it from Quick Launch or reinstall it.")
            case .launcherUnavailable:
                message = adbTVLocalized("No available launcher was found for this app. Check whether it is disabled on the TV.")
            default:
                message = fallback
            }
        } else {
            message = fallback
        }
        failure = DiagnosticDetail(summary: String(describing: error), context: ["operation": "quickLaunch"])
    }

    private static var previewApps: [ADBTVPinnedApp] {
        zip(["com.netflix.ninja", "com.google.android.youtube.tv", "com.example.longname"],
            ["Netflix", "YouTube", "A Streaming App With a Longer Name"])
            .compactMap { name, title in
                (try? ADBTVInstalledPackage(packageName: name)).map {
                    ADBTVPinnedApp(package: $0, displayName: title)
                }
            }
    }

    private var usesPreviewData: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-") })
#else
        false
#endif
    }
}

private struct ADBTVQuickLaunchManagementView: View {
    @Environment(\.dismiss) private var dismiss

    var apps: [ADBTVPinnedApp]
    var failureMessage: String?
    var isBusy: Bool
    var chooseApps: () -> Void
    var remove: (IndexSet) -> Void
    var move: (IndexSet, Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let failureMessage {
                    Text(failureMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    ForEach(apps) { app in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(app.title)
                                .fixedSize(horizontal: false, vertical: true)
                            if app.displayName != nil {
                                Text(app.packageName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .onDelete(perform: remove)
                    .onMove(perform: move)
                } footer: {
                    Text(adbTVLocalized("Keep up to six apps for this TV user. Reorder or remove them here; add apps from Apps → app actions → Pin to Remote."))
                }
                Button(adbTVLocalized("Choose Apps"), action: chooseApps)
            }
            .disabled(isBusy)
#if os(iOS)
            .environment(\.editMode, .constant(.active))
            .navigationBarTitleDisplayMode(.inline)
#endif
            .navigationTitle(adbTVLocalized("Quick Launch"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(adbTVLocalized("Done")) { dismiss() }
                }
            }
        }
    }
}
