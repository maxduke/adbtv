import ADBClientCore
import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import Photos
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ADBTVDeviceToolOperation: Equatable, Sendable {
    case information
    case screenshot
    case shell(command: String)

    var operationName: String {
        switch self {
        case .information: "loadDeviceInformation"
        case .screenshot: "captureScreenshot"
        case .shell: "runShellCommand"
        }
    }

    var failureMessage: String {
        switch self {
        case .information: "Could not load device information."
        case .screenshot: "Could not capture the TV screen."
        case .shell: "Could not run the shell command."
        }
    }
}

enum ADBTVDeviceToolResult: Equatable, Sendable {
    case information(ADBTVDeviceInformation)
    case screenshot(ADBTVScreenshot)
    case shell(ADBCheckedShellResult)
}

struct ADBTVDeviceToolsViewState: Equatable {
    var deviceID: ADBTVDeviceSummary.ID?
    var information: ADBTVDeviceInformation?
    var screenshot: ADBTVScreenshot?
    var shellResult: ADBCheckedShellResult?
    var informationStatus = ADBTVDeviceInformationStatus.idle
    var screenshotStatus = ADBTVScreenshotStatus.idle
    var shellStatus = ADBTVShellStatus.idle
    var activeOperation: ADBTVDeviceToolOperation?

    init(deviceID: ADBTVDeviceSummary.ID? = nil) {
        self.deviceID = deviceID
    }

    func forDevice(_ deviceID: ADBTVDeviceSummary.ID) -> Self {
        self.deviceID == deviceID ? self : Self(deviceID: deviceID)
    }

    mutating func start(_ operation: ADBTVDeviceToolOperation) {
        activeOperation = operation
        switch operation {
        case .information:
            informationStatus = .loading
        case .screenshot:
            screenshotStatus = .capturing
        case .shell:
            shellResult = nil
            shellStatus = .running
        }
    }

    mutating func finish(_ result: ADBTVDeviceToolResult) {
        activeOperation = nil
        switch result {
        case .information(let value):
            information = value
            informationStatus = .ready
        case .screenshot(let value):
            screenshot = value
            screenshotStatus = .ready
        case .shell(let value):
            shellResult = value
            shellStatus = .finished
        }
    }

    mutating func fail(
        _ operation: ADBTVDeviceToolOperation,
        userMessage: String,
        diagnosticDetail: DiagnosticDetail
    ) {
        activeOperation = nil
        switch operation {
        case .information:
            informationStatus = .failed(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        case .screenshot:
            screenshotStatus = .failed(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        case .shell:
            shellStatus = .failed(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        }
    }

    mutating func cancel() {
        guard let activeOperation else {
            return
        }
        self.activeOperation = nil
        switch activeOperation {
        case .information:
            informationStatus = information == nil ? .idle : .ready
        case .screenshot:
            screenshotStatus = screenshot == nil ? .idle : .ready
        case .shell:
            shellStatus = .idle
        }
    }

    static func preview(deviceID: ADBTVDeviceSummary.ID) -> Self {
        var state = Self(deviceID: deviceID)
        state.information = ADBTVDeviceInformation(
            device: ADBAndroidTVDeviceInfo(
                connectedDevice: ADBConnectedDevice(
                    protocolVersion: 0x01000001,
                    maxData: 1_048_576,
                    banner: "device::"
                ),
                manufacturer: "Google",
                model: "Google TV Streamer",
                productName: "mustang",
                deviceName: "mustang",
                androidVersion: "14",
                sdkVersion: "34",
                buildFingerprint: "google/mustang/mustang:14/UTT3.240625.001/12345678:user/release-keys"
            ),
            displaySize: ADBTVDisplaySize(width: 3840, height: 2160),
            storage: ADBTVStorageInfo(
                totalByteCount: 32_000_000_000,
                usedByteCount: 11_400_000_000,
                availableByteCount: 20_600_000_000
            ),
            uptime: ADBTVUptime(seconds: 360_300)
        )
        state.informationStatus = .ready
        state.shellResult = ADBCheckedShellResult(
            output: ADBShellOutput(bytes: Array("Android TV device connected\n".utf8)),
            exitCode: 0
        )
        state.shellStatus = .finished
        return state
    }
}

enum ADBTVDeviceInformationStatus: Equatable {
    case idle
    case loading
    case ready
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

enum ADBTVScreenshotStatus: Equatable {
    case idle
    case capturing
    case ready
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

enum ADBTVShellStatus: Equatable {
    case idle
    case running
    case finished
    case failed(userMessage: String, diagnosticDetail: DiagnosticDetail)
}

struct ADBTVShellPreset: Identifiable {
    let title: String
    let command: String
    var id: String { command }

    static let all = [
        Self(title: "Device Properties", command: "getprop"),
        Self(title: "Network Interfaces", command: "ip addr show"),
        Self(title: "Storage Usage", command: "df -h"),
        Self(title: "Third-party Apps", command: "pm list packages -3"),
        Self(title: "Recent System Log", command: "logcat -d -t 200")
    ]
}

struct ADBTVDeviceToolsPanel: View {
    var state: ADBTVDeviceToolsViewState
    var deviceOperationInProgress: Bool
    var loadInformation: () -> Void
    var captureScreenshot: () -> Void
    var runShellCommand: (String) -> Void
    var cancel: () -> Void

    @State private var shellCommand = ProcessInfo.processInfo.arguments.contains("--ui-tools")
        ? "getprop ro.build.version.release"
        : ""
#if os(iOS)
    @State private var savingScreenshot = false
    @State private var photoSaveMessage: String?
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            informationSection
            Divider()
            screenshotSection
            Divider()
            shellSection
        }
        .onAppear {
            if state.informationStatus == .idle {
                loadInformation()
            }
        }
#if os(iOS)
        .alert(
            "Screenshot",
            isPresented: Binding(
                get: { photoSaveMessage != nil },
                set: { if !$0 { photoSaveMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoSaveMessage ?? "")
        }
#endif
    }

    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                "Device Information",
                systemImage: "info.circle",
                actionLabel: "Refresh Device Information",
                actionImage: "arrow.clockwise",
                action: loadInformation,
                disabled: deviceOperationInProgress
            )

            switch state.informationStatus {
            case .loading:
                progressRow("Loading device information")
            case .failed(let userMessage, let diagnosticDetail):
                failureView(userMessage, diagnosticDetail: diagnosticDetail)
            case .idle, .ready:
                if let information = state.information {
                    informationContent(information)
                } else {
                    ContentUnavailableView("No Device Information", systemImage: "info.circle")
                }
            }
        }
    }

    private func informationContent(_ information: ADBTVDeviceInformation) -> some View {
        VStack(spacing: 0) {
            informationRow("Manufacturer", value: information.device.manufacturer)
            informationRow("Model", value: information.device.model)
            informationRow("Android", value: androidVersion(information))
            informationRow("Product", value: information.device.productName)
            informationRow("Device", value: information.device.deviceName)

            if let size = information.displaySize {
                informationRow("Resolution", value: "\(size.width) x \(size.height)")
            }
            if let uptime = information.uptime {
                informationRow("Uptime", value: formattedUptime(uptime.seconds))
            }
            if let storage = information.storage {
                storageRow(storage)
            }

            informationRow(
                "Build",
                value: information.device.buildFingerprint,
                monospaced: true
            )
        }
    }

    @ViewBuilder
    private func informationRow(
        _ label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        if !value.isEmpty {
            LabeledContent(label) {
                Text(value)
                    .font(monospaced ? .footnote.monospaced() : .body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 8)
            Divider()
        }
    }

    private func storageRow(_ storage: ADBTVStorageInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Storage")
                Spacer()
                Text(
                    "\(formattedBytes(storage.usedByteCount)) of "
                        + "\(formattedBytes(storage.totalByteCount)) used"
                )
                .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(storage.usedByteCount),
                total: max(Double(storage.totalByteCount), 1)
            )
            Text("\(formattedBytes(storage.availableByteCount)) available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Screenshot", systemImage: "photo")
                    .font(.title2.bold())
                Spacer()

                if let screenshot = state.screenshot,
                   let image = platformImage(from: screenshot.pngData) {
#if os(iOS)
                    Button {
                        saveScreenshotToPhotos(screenshot.pngData)
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(deviceOperationInProgress || savingScreenshot)
                    .help("Save to Photos")
#endif

                    ShareLink(
                        item: ADBTVScreenshotShareItem(pngData: screenshot.pngData),
                        preview: SharePreview("Android TV Screenshot", image: image)
                    ) {
                        Label("Share Screenshot", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(deviceOperationInProgress)
                    .help("Share Screenshot")
                }

                Button(action: captureScreenshot) {
                    Label("Capture Screenshot", systemImage: "camera.viewfinder")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(deviceOperationInProgress)
                .help("Capture Screenshot")
            }

            screenshotPreview

            switch state.screenshotStatus {
            case .capturing:
                progressRow("Capturing TV screen")
            case .failed(let userMessage, let diagnosticDetail):
                failureView(userMessage, diagnosticDetail: diagnosticDetail)
            case .idle, .ready:
                EmptyView()
            }
        }
    }

    private var screenshotPreview: some View {
        ZStack {
            Color.black

            if let screenshot = state.screenshot,
               let image = platformImage(from: screenshot.pngData) {
                image
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Captured Android TV screen")
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.55))
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(screenshotAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        }
    }

    private var shellSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("ADB Shell", systemImage: "terminal")
                    .font(.title2.bold())
                Spacer()
                Menu {
                    ForEach(ADBTVShellPreset.all) { preset in
                        Button {
                            shellCommand = preset.command
                        } label: {
                            Label(preset.title, systemImage: "terminal")
                        }
                    }
                } label: {
                    Label("Commands", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(deviceOperationInProgress)
                .help("Built-in Commands")
            }

            HStack(alignment: .bottom, spacing: 10) {
                shellCommandField

                Button(action: runShell) {
                    Label("Run Command", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    deviceOperationInProgress
                        || shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help("Run Command")
            }

            shellOutput

            switch state.shellStatus {
            case .running:
                progressRow("Running shell command")
            case .failed(let userMessage, let diagnosticDetail):
                failureView(userMessage, diagnosticDetail: diagnosticDetail)
            case .idle, .finished:
                EmptyView()
            }
        }
    }

    private var shellOutput: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Output")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let result = state.shellResult {
                    Label(
                        "Exit \(result.exitCode)",
                        systemImage: result.exitCode == 0
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.exitCode == 0 ? .green : .orange)
                }
            }

            ScrollView([.horizontal, .vertical]) {
                Text(shellOutputText)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 1, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .topLeading)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var shellCommandField: some View {
#if os(iOS)
        TextField("Command", text: $shellCommand, axis: .vertical)
            .font(.body.monospaced())
            .lineLimit(1 ... 4)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.send)
            .onSubmit(runShell)
#else
        TextField("Command", text: $shellCommand, axis: .vertical)
            .font(.body.monospaced())
            .lineLimit(1 ... 4)
            .autocorrectionDisabled()
            .onSubmit(runShell)
#endif
    }

    private func sectionHeader(
        _ title: String,
        systemImage: String,
        actionLabel: String,
        actionImage: String,
        action: @escaping () -> Void,
        disabled: Bool
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.title2.bold())
            Spacer()
            Button(action: action) {
                Label(actionLabel, systemImage: actionImage)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(disabled)
            .help(actionLabel)
        }
    }

    private func progressRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: cancel) {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
        }
    }

    private func failureView(
        _ userMessage: String,
        diagnosticDetail: DiagnosticDetail
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
        }
    }

    private func runShell() {
        let command = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !deviceOperationInProgress else {
            return
        }
        runShellCommand(command)
    }

#if os(iOS)
    private func saveScreenshotToPhotos(_ pngData: Data) {
        guard !savingScreenshot else {
            return
        }
        savingScreenshot = true

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                guard status == .authorized || status == .limited else {
                    savingScreenshot = false
                    photoSaveMessage = "Photo access was not allowed. "
                        + "You can enable Add Photos Only access in Settings."
                    return
                }

                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = "ADB-TV-Screenshot.png"
                        request.addResource(with: .photo, data: pngData, options: options)
                    }
                    photoSaveMessage = "Saved to Photos."
                } catch {
                    photoSaveMessage = "Could not save the screenshot to Photos: "
                        + error.localizedDescription
                }
                savingScreenshot = false
            }
        }
    }
#endif

    private func androidVersion(_ information: ADBTVDeviceInformation) -> String {
        guard !information.device.sdkVersion.isEmpty else {
            return information.device.androidVersion
        }
        return "\(information.device.androidVersion) (API \(information.device.sdkVersion))"
    }

    private func formattedBytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func formattedUptime(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds) / 60, 0)
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private var screenshotAspectRatio: CGFloat {
        guard let screenshot = state.screenshot, screenshot.height > 0 else {
            return 16 / 9
        }
        return CGFloat(screenshot.width) / CGFloat(screenshot.height)
    }

    private var shellOutputText: String {
        guard let result = state.shellResult else {
            return "No output"
        }
        return result.output.utf8String.isEmpty
            ? "(command produced no output)"
            : result.output.utf8String
    }

    private func platformImage(from data: Data) -> Image? {
#if os(iOS)
        UIImage(data: data).map { Image(uiImage: $0) }
#elseif os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
#else
        nil
#endif
    }
}

private struct ADBTVScreenshotShareItem: Transferable {
    var pngData: Data

    var suggestedFilename: String? {
        "ADB-TV-Screenshot.png"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.pngData
        }
    }
}
