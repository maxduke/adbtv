import ADBClientCore
import SwiftUI

@MainActor
struct ADBTVFileUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let queue: ADBTVFileUploadQueue
    let device: ADBTVDeviceSummary
    let directory: ADBSharedStoragePath

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        Text(phaseTitle)
                            .font(.headline)
                            .id("uploadSummary")
                        Text(adbTVLocalized("Files processed: %@ of %@", String(queue.processedCount), String(queue.items.count)))
                        ProgressView(value: Double(queue.processedCount), total: Double(queue.items.count))
                    }

                    if queue.isActive, let index = queue.currentIndex {
                        Section(adbTVLocalized("Current File")) {
                            itemContents(queue.items[index])
                                .id("currentUpload")
                        }
                    }

                    if let failure = queue.failure {
                        Section {
                            Label(
                                queue.cleanupFailed
                                    ? adbTVLocalized("Could not remove the upload's temporary file. See Technical Details.")
                                    : adbTVLocalized("Uploads stopped. Completed files are kept."),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.red)
                            DiagnosticDisclosure(diagnosticDetail: failure)
                        }
                    }

                    if !queue.isActive {
                        Section {
                            Text(adbTVLocalized("Uploaded: %@ · Skipped: %@ · Unfinished: %@", String(queue.uploadedCount), String(queue.skippedCount), String(queue.unfinishedCount)))
                            if queue.phase == .cancelled || queue.phase == .failed {
                                Text(adbTVLocalized("Completed files are kept."))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        DisclosureGroup {
                            Text(device.localizedConnectionDescription)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(device.displayName, systemImage: "tv")
                                    .font(.subheadline)
                                Text(directory.rawValue)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    Section(adbTVLocalized("Files")) {
                        ForEach(queue.items) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(item.name)
                                    .font(.body.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                Label(itemTitle(item), systemImage: itemIcon(item))
                                    .font(.subheadline)
                                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                            }
                            .padding(.vertical, 4)
                            .id(item.id)
                        }
                    }
                }
                .onChange(of: queue.hasConflict, initial: true) { _, hasConflict in
                    if hasConflict {
                        proxy.scrollTo("currentUpload", anchor: .top)
                    }
                }
                .onChange(of: queue.phase) { _, _ in
                    if !queue.isActive {
                        proxy.scrollTo("uploadSummary", anchor: .top)
                    }
                }
            }
            .navigationTitle(adbTVLocalized("Upload Files"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if queue.isActive {
                        Button(adbTVLocalized("Cancel")) { queue.cancel() }
                            .disabled(queue.phase == .cancelling)
                    } else {
                        Button(adbTVLocalized("Done")) { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(queue.isActive)
        .onDisappear { queue.cancel() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { queue.cancel() }
        }
    }

    private func itemContents(_ item: ADBTVFileUploadQueue.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Label(itemTitle(item), systemImage: itemIcon(item))
                .foregroundStyle(.secondary)
            if item.state == .uploading {
                if let fraction = item.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text(byteDetail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.state == .conflict, queue.hasConflict {
                conflictActions
            }
        }
        .padding(.vertical, 4)
    }

    private var conflictActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(queue.canReplace
                ? adbTVLocalized("Replacing permanently overwrites this file. You can skip it instead.")
                : adbTVLocalized("A folder, link, or other non-file item has this name. It cannot be replaced."))
            if queue.canReplace {
                Button(adbTVLocalized("Replace File"), role: .destructive) {
                    queue.resolveConflict(.replace)
                }
                .buttonStyle(.bordered)
            }
            Button(adbTVLocalized("Skip File")) { queue.resolveConflict(.skip) }
                .buttonStyle(.bordered)
            Text(adbTVLocalized("Cancel stops all remaining uploads."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var phaseTitle: String {
        switch queue.phase {
        case .ready: return adbTVLocalized("Preparing uploads")
        case .running: return queue.hasConflict
            ? adbTVLocalized("Choose how to handle this item") : adbTVLocalized("Uploading files")
        case .cancelling: return adbTVLocalized("Cancelling and cleaning up")
        case .finished: return adbTVLocalized("Uploads finished")
        case .cancelled: return adbTVLocalized("Cancelled")
        case .failed: return adbTVLocalized("Uploads stopped")
        }
    }

    private func itemTitle(_ item: ADBTVFileUploadQueue.Item) -> String {
        switch item.state {
        case .queued: return queue.isActive ? adbTVLocalized("Waiting") : adbTVLocalized("Not uploaded")
        case .checking: return adbTVLocalized("Checking destination")
        case .uploading: return adbTVLocalized("Uploading")
        case .conflict: return adbTVLocalized("Needs a decision")
        case .uploaded: return adbTVLocalized("Uploaded")
        case .skipped: return adbTVLocalized("Skipped")
        case .cancelled: return adbTVLocalized("Cancelled")
        case .failed: return adbTVLocalized("Failed")
        }
    }

    private func itemIcon(_ item: ADBTVFileUploadQueue.Item) -> String {
        switch item.state {
        case .uploaded: return "checkmark.circle.fill"
        case .skipped: return "forward.end"
        case .failed: return "exclamationmark.triangle.fill"
        case .conflict: return "questionmark.circle"
        case .cancelled: return "xmark.circle"
        case .queued, .checking: return "clock"
        case .uploading: return "arrow.up.doc"
        }
    }

    private func byteDetail(_ item: ADBTVFileUploadQueue.Item) -> String {
        let completed = ByteCountFormatter.string(fromByteCount: item.completedByteCount, countStyle: .file)
        guard let total = item.totalByteCount else { return completed }
        return adbTVLocalized("%@ of %@", completed, ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
    }
}
