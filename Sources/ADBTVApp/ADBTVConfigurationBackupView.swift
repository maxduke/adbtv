import ADBClientCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ADBTVConfigurationBackupView: View {
    @Environment(\.dismiss) private var dismiss
    let deviceStore: ADBTVDeviceStore
    let restore: @MainActor (ADBTVConfigurationRestorePlan, Set<UUID>) throws -> ADBTVConfigurationRestoreReport

    @State private var plan: ADBTVConfigurationRestorePlan?
    @State private var selectedIDs: Set<UUID> = []
    @State private var report: ADBTVConfigurationRestoreReport?
    @State private var errorMessage: String?
    @State private var didExport = false
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var document: ADBTVConfigurationDocument?
    @State private var readTask: Task<Void, Never>?
    @State private var requestID: UUID?

    private var store: ADBTVConfigurationBackupStore { .init(deviceStore: deviceStore) }
    private var isPreview: Bool { ProcessInfo.processInfo.arguments.contains("--ui-backup") }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if let plan {
                    previewSections(plan)
                } else {
                    homeSections
                }
            }
            .navigationTitle(plan == nil ? adbTVLocalized("Backup and Restore") : adbTVLocalized("Review Backup"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(readTask != nil || plan != nil ? adbTVLocalized("Cancel") : adbTVLocalized("Done")) {
                        if readTask != nil { readTask?.cancel() }
                        else if plan != nil { self.plan = nil; selectedIDs = []; errorMessage = nil }
                        else { dismiss() }
                    }
                }
                if plan != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(adbTVLocalized("Restore Selected"), action: restoreSelected)
                            .disabled(selectedIDs.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(readTask != nil)
        .onDisappear { readTask?.cancel(); requestID = nil }
        .onAppear(perform: preparePreview)
#if os(iOS)
        .sheet(isPresented: $isImporterPresented) {
            ADBTVDocumentPicker(allowedContentTypes: [.json]) { result in
                isImporterPresented = false
                switch result {
                case .success(let urls): if let url = urls.first { readBackup(url) }
                case .failure: errorMessage = adbTVLocalized("Could not open the selected backup.")
                }
            }
        }
#else
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): readBackup(url)
            case .failure: errorMessage = adbTVLocalized("Could not open the selected backup.")
            }
        }
#endif
        .fileExporter(isPresented: $isExporterPresented, document: document, contentType: .json, defaultFilename: "ADBTV-configuration") { result in
            switch result {
            case .success: didExport = true
            case .failure: errorMessage = adbTVLocalized("Could not save the backup. Choose another location and try again.")
            }
            document = nil
        }
    }

    @ViewBuilder
    private var homeSections: some View {
        if let report {
            Section {
                Label(adbTVLocalized("Configuration restored"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(adbTVLocalized("Added: %@ · Skipped: %@", String(report.addedCount), String(report.skippedCount)))
                Text(adbTVLocalized("Existing devices and their Quick Launch pins were kept. Select a restored TV to reconnect; pair again if asked."))
            }
        }
        if didExport {
            Section {
                Label(adbTVLocalized("Backup saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        if readTask != nil {
            Section {
                HStack(spacing: 12) { ProgressView(); Text(adbTVLocalized("Reading backup")) }
            }
        }
        Section {
            Button(action: exportBackup) {
                Label(adbTVLocalized("Export Backup"), systemImage: "square.and.arrow.up")
            }
            .disabled(readTask != nil)
            Button {
                guard !isPreview else { return }
                errorMessage = nil
                isImporterPresented = true
            } label: {
                Label(adbTVLocalized("Import Backup"), systemImage: "square.and.arrow.down")
            }
            .disabled(readTask != nil)
        } footer: {
            Text(adbTVLocalized("Back up saved TV connections and Quick Launch pins by TV user. Pairing keys, passwords, and TV app data are not included."))
        }
        Section {
            Text(adbTVLocalized("Import adds only the new devices you select. Already-saved devices and their preferences are skipped."))
            Text(adbTVLocalized("Restoring configuration does not connect to a TV or restore pairing trust. Keep the backup private; it contains device addresses and app names."))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func previewSections(_ plan: ADBTVConfigurationRestorePlan) -> some View {
        Section {
            Text(adbTVLocalized("Selected %@ of %@ new devices", String(selectedIDs.count), String(plan.newDeviceIDs.count)))
                .font(.headline)
            Text(adbTVLocalized("Review the names, addresses, and saved TV users before restoring."))
        }
        if plan.newDeviceIDs.isEmpty {
            Section {
                Label(adbTVLocalized("No New Devices"), systemImage: "checkmark.circle")
                Text(adbTVLocalized("There is nothing to add. Existing configuration will remain unchanged."))
            }
        } else {
            Section(adbTVLocalized("New Devices")) {
                ForEach(plan.rows.filter { !$0.alreadySaved }) { row in
                    Toggle(isOn: Binding(
                        get: { selectedIDs.contains(row.id) },
                        set: { if $0 { selectedIDs.insert(row.id) } else { selectedIDs.remove(row.id) } }
                    )) { recordLabel(row.record) }
                }
            }
        }
        let duplicates = plan.rows.filter(\.alreadySaved)
        if !duplicates.isEmpty {
            Section(adbTVLocalized("Already Saved — Skipped")) {
                ForEach(duplicates) { row in recordLabel(row.record) }
            }
        }
        Section {
            Text(adbTVLocalized("Current names, connections, and favorites are kept for already-saved devices."))
            Text(adbTVLocalized("Quick Launch pins retain their saved TV user IDs. Reconnect to the original TV before using them."))
                .foregroundStyle(.secondary)
        }
    }

    private func recordLabel(_ record: ADBTVConfigurationBackup.Device) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.displayName).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(record.summary.localizedConnectionDescription)
                .font(.footnote.monospaced()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(adbTVLocalized("Pinned apps: %@ · TV users: %@", String(record.quickLaunch.reduce(0) { $0 + $1.apps.count }), String(record.quickLaunch.count)))
                .font(.footnote).foregroundStyle(.secondary)
            if !record.quickLaunch.isEmpty {
                let users = record.quickLaunch.prefix(8).map { String($0.userID) }.joined(separator: ", ")
                Text(record.quickLaunch.count > 8
                    ? adbTVLocalized("TV users: %@ (+%@ more)", users, String(record.quickLaunch.count - 8))
                    : adbTVLocalized("TV users: %@", users))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func exportBackup() {
        guard !isPreview else { return }
        errorMessage = nil
        didExport = false
        do {
            document = ADBTVConfigurationDocument(data: try store.export())
            isExporterPresented = true
        } catch { show(error) }
    }

    private func readBackup(_ url: URL) {
        guard readTask == nil else { return }
        plan = nil; report = nil; errorMessage = nil; didExport = false
        let id = UUID()
        requestID = id
        readTask = Task {
            defer { if requestID == id { readTask = nil; requestID = nil } }
            do {
                let backup = try await ADBTVConfigurationBackup.read(from: url)
                try Task.checkCancellation()
                guard requestID == id else { return }
                let preview = try store.preview(backup)
                selectedIDs = preview.newDeviceIDs
                plan = preview
            } catch {
                guard requestID == id, !Task.isCancelled, !(error is CancellationError) else { return }
                show(error)
            }
        }
    }

    private func restoreSelected() {
        guard !isPreview, let plan else { return }
        do {
            report = try restore(plan, selectedIDs)
            self.plan = nil
            selectedIDs = []
            errorMessage = nil
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        errorMessage = (error as? ADBTVConfigurationBackupError)?.userMessage
            ?? adbTVLocalized("Could not restore or export configuration. Existing data was preserved.")
    }

    private func preparePreview() {
        guard isPreview, plan == nil, report == nil, errorMessage == nil else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--ui-backup"), args.indices.contains(index + 1) else { return }
        let scenario = args[index + 1]
        if scenario == "failed" { errorMessage = ADBTVConfigurationBackupError.invalidBackup.userMessage; return }
        if scenario == "exported" { didExport = true; return }
        guard scenario == "review" || scenario == "duplicates" || scenario == "restored" else { return }
        do {
            let suite = "ADBTVBackupPreview.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }
            let saved = ADBTVDeviceSummary(displayName: "Living Room TV", host: "192.168.1.50", port: 5555)
            let bedroom = ADBTVDeviceSummary(displayName: "Bedroom Android TV with a Longer Name · 卧室电视", host: "bedroom-tv.local", port: 5555)
            let guest = ADBTVDeviceSummary(displayName: "Guest Room TV", host: "192.168.1.52", port: 4567)
            let devices = ADBTVDeviceStore(userDefaults: defaults)
            try devices.saveDevices([saved])
            let package = try ADBTVInstalledPackage(packageName: "com.example.player")
            let groups = [ADBTVQuickLaunchStore.UserApps(userID: 0, apps: [.init(package: package, displayName: "Player")]), .init(userID: 10, apps: [.init(package: package, displayName: "Player")])]
            let backup = try ADBTVConfigurationBackup(devices: (scenario == "duplicates" ? [saved] : [saved, bedroom, guest]).map {
                try .init($0, quickLaunch: groups)
            })
            if scenario == "restored" {
                report = .init(devices: [saved, bedroom, guest], addedCount: 2, skippedCount: 1)
            } else {
                let value = try ADBTVConfigurationBackupStore(deviceStore: devices).preview(backup)
                plan = value
                selectedIDs = value.newDeviceIDs
            }
        } catch { show(error) }
    }
}

private struct ADBTVConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let value = configuration.file.regularFileContents,
              value.count <= ADBTVConfigurationBackup.maximumByteCount else { throw ADBTVConfigurationBackupError.tooLarge }
        data = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
