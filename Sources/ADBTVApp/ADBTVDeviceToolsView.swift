import ADBClientCore
import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ADBTVDeviceToolOperation: Equatable, Sendable {
    case information
    case cacheCleanup(desiredFreeByteCount: Int64)
    case screenshot
    case shell(command: String)

    var operationName: String {
        switch self {
        case .information: "loadDeviceInformation"
        case .cacheCleanup: "trimAppCaches"
        case .screenshot: "captureScreenshot"
        case .shell: "runShellCommand"
        }
    }

    var failureMessage: String {
        switch self {
        case .information: adbTVLocalized("Could not load device information.")
        case .cacheCleanup: adbTVLocalized("Could not clean app caches.")
        case .screenshot: adbTVLocalized("Could not capture the TV screen.")
        case .shell: adbTVLocalized("Could not run the shell command.")
        }
    }
}

enum ADBTVDeviceToolResult: Equatable, Sendable {
    case information(ADBTVDeviceInformation)
    case cacheCleanup(ADBTVDeviceInformation)
    case screenshot(ADBTVScreenshot, assessment: ADBTVScreenshotAssessment)
    case shell(ADBCheckedShellResult)
}

struct ADBTVDeviceToolsViewState: Equatable {
    var deviceID: ADBTVDeviceSummary.ID?
    var information: ADBTVDeviceInformation?
    var screenshot: ADBTVScreenshot?
    var screenshotAssessment: ADBTVScreenshotAssessment?
    var shellResult: ADBCheckedShellResult?
    var submittedShellCommand: String?
    var informationStatus = ADBTVDeviceInformationStatus.idle
    var cacheCleanupStatus = ADBTVCacheCleanupStatus.idle
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
        case .cacheCleanup:
            cacheCleanupStatus = .running
        case .screenshot:
            screenshotStatus = .capturing
        case .shell(let command):
            submittedShellCommand = command
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
        case .cacheCleanup(let value):
            information = value
            informationStatus = .ready
            cacheCleanupStatus = .finished
        case .screenshot(let value, let assessment):
            screenshot = value
            screenshotAssessment = assessment
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
        case .cacheCleanup:
            cacheCleanupStatus = .failed(
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
        case .cacheCleanup:
            cacheCleanupStatus = .idle
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
        state.submittedShellCommand = "getprop ro.build.version.release"
        state.shellStatus = .finished
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-blank") {
            let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAFElEQVR4nGNgYGD4TyEeNWDUgP8AGCaPcSyJNrgAAAAASUVORK5CYII=")!
            state.finish(.screenshot(try! ADBTVScreenshot(pngData: data), assessment: .appearsBlank))
        } else if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-content") {
            let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAFklEQVR4nGNQLrjznxLMMGrAqAFADAAEGl3wf2IiSgAAAABJRU5ErkJggg==")!
            state.finish(.screenshot(try! ADBTVScreenshot(pngData: data), assessment: .content))
        } else if ProcessInfo.processInfo.arguments.contains("--ui-screenshot-invalid") {
            state.fail(.screenshot,
                       userMessage: adbTVLocalized("The TV returned an image that could not be decoded safely. Try capturing the TV Home screen again."),
                       diagnosticDetail: DiagnosticDetail(summary: "Preview undecodable PNG."))
        }
#endif
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

enum ADBTVCacheCleanupStatus: Equatable {
    case idle
    case running
    case finished
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
        Self(title: adbTVLocalized("Device Properties"), command: "getprop"),
        Self(title: adbTVLocalized("Network Interfaces"), command: "ip addr show"),
        Self(title: adbTVLocalized("Storage Usage"), command: "df -h"),
        Self(title: adbTVLocalized("Third-party Apps"), command: "pm list packages -3"),
        Self(title: adbTVLocalized("Recent System Log"), command: "logcat -d -t 200")
    ]
}

struct ADBTVDeviceToolsPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var state: ADBTVDeviceToolsViewState
    var deviceOperationInProgress: Bool
    var loadInformation: () -> Void
    var captureScreenshot: () -> Void
    var runShellCommand: (String) -> Void
    var openFiles: () -> Void
    var cleanCaches: () -> Void
    var cancel: () -> Void

    @State private var shellCommand = ProcessInfo.processInfo.arguments.contains("--ui-tools")
        ? "getprop ro.build.version.release"
        : ""
    @State private var isCacheCleanupConfirmationPresented = false
    @State private var isInformationExpanded = false
    @State private var isShellExpanded = false

    private var isScreenshotPreview: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-screenshot-") }
#else
        false
#endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !isScreenshotPreview {
                storageManagementSection
                Divider()
                informationSection
                Divider()
            }
            screenshotSection
            if !isScreenshotPreview {
                Divider()
                shellSection
            }
        }
        .onAppear {
            if state.informationStatus == .idle {
                loadInformation()
            }
        }
        .alert(adbTVLocalized("Clear App Caches?"), isPresented: $isCacheCleanupConfirmationPresented) {
            Button(adbTVLocalized("Clear Caches"), role: .destructive) { cleanCaches() }
            Button(adbTVLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(adbTVLocalized("Android will remove temporary app data. Apps may load more slowly the next time they open."))
        }
    }

    private var storageManagementSection: some View {
        VStack(spacing: 16) {
            filesSection
            Divider()
            cacheCleanupSection
        }
    }

    private var filesSection: some View {
        Button(action: openFiles) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(adbTVLocalized("Files"))
                        .font(.headline)
                    Text(adbTVLocalized("Browse shared storage"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(deviceOperationInProgress)
        .accessibilityHint(adbTVLocalized("Opens shared storage on the Android TV"))
    }

    private var cacheCleanupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(adbTVLocalized("Storage Cleanup"))
                        .font(.headline)
                    Text(adbTVLocalized("Remove temporary app caches"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if state.cacheCleanupStatus == .running {
                    ProgressView()
                    Button(action: cancel) {
                        Label(adbTVLocalized("Cancel Cache Cleanup"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        isCacheCleanupConfirmationPresented = true
                    } label: {
                        Label(adbTVLocalized("Clear App Caches"), systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(deviceOperationInProgress)
                }
            }

            switch state.cacheCleanupStatus {
            case .finished:
                Label(adbTVLocalized("App caches cleaned."), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            case .failed(let userMessage, let diagnosticDetail):
                failureView(userMessage, diagnosticDetail: diagnosticDetail)
            case .idle, .running:
                EmptyView()
            }
        }
    }

    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    isInformationExpanded.toggle()
                } label: {
                    HStack {
                        Label(adbTVLocalized("Device Information"), systemImage: "info.circle")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isInformationExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.informationStatus == .loading)
                .accessibilityValue(isInformationExpanded ? adbTVLocalized("Expanded") : adbTVLocalized("Collapsed"))

                if isInformationExpanded {
                    Button(action: loadInformation) {
                        Label(adbTVLocalized("Refresh Device Information"), systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled(deviceOperationInProgress)
                    .help(adbTVLocalized("Refresh Device Information"))
                }
            }

            if isInformationExpanded {
                switch state.informationStatus {
                case .loading:
                    progressRow(adbTVLocalized("Loading device information"))
                case .failed(let userMessage, let diagnosticDetail):
                    failureView(userMessage, diagnosticDetail: diagnosticDetail)
                case .idle, .ready:
                    if let information = state.information {
                        informationContent(information)
                    } else {
                        ContentUnavailableView(adbTVLocalized("No Device Information"), systemImage: "info.circle")
                    }
                }
            }
        }
    }

    private func informationContent(_ information: ADBTVDeviceInformation) -> some View {
        VStack(spacing: 0) {
            informationRow(adbTVLocalized("Manufacturer"), value: information.device.manufacturer)
            informationRow(adbTVLocalized("Model"), value: information.device.model)
            informationRow("Android", value: androidVersion(information))
            informationRow(adbTVLocalized("Product"), value: information.device.productName)
            informationRow(adbTVLocalized("Device"), value: information.device.deviceName)

            if let size = information.displaySize {
                informationRow(adbTVLocalized("Resolution"), value: "\(size.width) x \(size.height)")
            }
            if let uptime = information.uptime {
                informationRow(adbTVLocalized("Uptime"), value: formattedUptime(uptime.seconds))
            }
            if let storage = information.storage {
                storageRow(storage)
            }

            informationRow(
                adbTVLocalized("Build"),
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
                Text(adbTVLocalized("Storage"))
                Spacer()
                Text(
                    adbTVLocalized("%@ of %@ used", String(describing: formattedBytes(storage.usedByteCount)), String(describing: formattedBytes(storage.totalByteCount)))
                )
                .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(storage.usedByteCount),
                total: max(Double(storage.totalByteCount), 1)
            )
            Text(adbTVLocalized("%@ available", String(describing: formattedBytes(storage.availableByteCount))))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    screenshotTitle
                    HStack {
                        Spacer()
                        screenshotActions
                    }
                }
            } else {
                HStack(spacing: 10) {
                    screenshotTitle
                    Spacer()
                    screenshotActions
                }
            }

            if state.screenshotAssessment == .appearsBlank {
                Label(adbTVLocalized("The TV returned a black or transparent image. Some video apps or TVs block screen capture. Try the TV Home screen or Settings, then capture again."),
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.screenshot != nil {
                screenshotPreview
            }

            switch state.screenshotStatus {
            case .capturing:
                progressRow(adbTVLocalized("Capturing TV screen"))
            case .failed(let userMessage, let diagnosticDetail):
                failureView(userMessage, diagnosticDetail: diagnosticDetail)
            case .idle, .ready:
                EmptyView()
            }
        }
    }

    private var screenshotTitle: some View {
        Label(adbTVLocalized("Screenshot"), systemImage: "photo")
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var screenshotActions: some View {
        HStack(spacing: 10) {
            if let screenshot = state.screenshot,
               let image = platformImage(from: screenshot.pngData) {
                ShareLink(
                    item: ADBTVScreenshotShareItem(pngData: screenshot.pngData),
                    preview: SharePreview(adbTVLocalized("Android TV Screenshot"), image: image)
                ) {
                    Label(adbTVLocalized("Share Screenshot"), systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(deviceOperationInProgress)
                .help(adbTVLocalized("Share Screenshot"))
            }
            Button(action: captureScreenshot) {
                Label(adbTVLocalized("Capture Screenshot"), systemImage: "camera.viewfinder")
                    .labelStyle(.iconOnly)
            }
            .adbTVProminentButton()
            .disabled(deviceOperationInProgress)
            .help(adbTVLocalized("Capture Screenshot"))
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
                    .accessibilityLabel(adbTVLocalized("Captured Android TV screen"))
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
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    shellDisclosure
                    commandsMenu
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 10) {
                    shellDisclosure
                    commandsMenu
                }
            }

            if isShellExpanded {
                HStack(alignment: .bottom, spacing: 10) {
                    shellCommandField

                    Button(action: runShell) {
                        Label(adbTVLocalized("Run Command"), systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                    .adbTVProminentButton()
                    .disabled(
                        deviceOperationInProgress
                            || shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .help(adbTVLocalized("Run Command"))
                }

                if state.submittedShellCommand != nil {
                    shellTranscript
                }

                switch state.shellStatus {
                case .running:
                    progressRow(adbTVLocalized("Running shell command"))
                case .failed(let userMessage, let diagnosticDetail):
                    failureView(userMessage, diagnosticDetail: diagnosticDetail)
                case .idle, .finished:
                    EmptyView()
                }
            }
        }
    }

    private var shellDisclosure: some View {
        Button {
            isShellExpanded.toggle()
        } label: {
            HStack {
                Label(adbTVLocalized("ADB Shell"), systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isShellExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.shellStatus == .running)
        .accessibilityValue(isShellExpanded ? adbTVLocalized("Expanded") : adbTVLocalized("Collapsed"))
    }

    private var commandsMenu: some View {
        Menu {
            ForEach(ADBTVShellPreset.all) { preset in
                Button {
                    shellCommand = preset.command
                    isShellExpanded = true
                } label: {
                    Label(preset.title, systemImage: "terminal")
                }
            }
        } label: {
            Label(adbTVLocalized("Commands"), systemImage: "list.bullet.rectangle")
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    alignment: .leading
                )
        }
        .buttonStyle(.bordered)
        .disabled(deviceOperationInProgress)
        .help(adbTVLocalized("Built-in Commands"))
    }

    private var shellTranscript: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = state.submittedShellCommand {
                ScrollView(.horizontal) {
                    Text("$ \(command)")
                        .font(.footnote.monospaced())
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(adbTVLocalized("Submitted command"))
                .accessibilityValue(command)
            }

            if let result = state.shellResult {
                Divider()
                HStack {
                    Text(adbTVLocalized("Output"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Label(
                        adbTVLocalized("Exit %@", String(describing: result.exitCode)),
                        systemImage: result.exitCode == 0
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.exitCode == 0 ? Color.accentColor : Color.orange)
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
        TextField(adbTVLocalized("Command"), text: $shellCommand)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.send)
            .onSubmit(runShell)
#else
        TextField(adbTVLocalized("Command"), text: $shellCommand, axis: .vertical)
            .font(.body.monospaced())
            .lineLimit(1 ... 4)
            .autocorrectionDisabled()
            .onSubmit(runShell)
#endif
    }

    private func progressRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: cancel) {
                Label(adbTVLocalized("Cancel"), systemImage: "xmark")
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
        shellCommand = ""
    }

    private func androidVersion(_ information: ADBTVDeviceInformation) -> String {
        guard !information.device.sdkVersion.isEmpty else {
            return information.device.androidVersion
        }
        return adbTVLocalized("%@ (API %@)", String(describing: information.device.androidVersion), String(describing: information.device.sdkVersion))
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
            return adbTVLocalized("%@d %@h", days.formatted(), hours.formatted())
        }
        if hours > 0 {
            return adbTVLocalized("%@h %@m", hours.formatted(), minutes.formatted())
        }
        return adbTVLocalized("%@m", minutes.formatted())
    }

    private var screenshotAspectRatio: CGFloat {
        guard let screenshot = state.screenshot, screenshot.height > 0 else {
            return 16 / 9
        }
        return CGFloat(screenshot.width) / CGFloat(screenshot.height)
    }

    private var shellOutputText: String {
        guard let result = state.shellResult else {
            return adbTVLocalized("No output")
        }
        return result.output.utf8String.isEmpty
            ? adbTVLocalized("(command produced no output)")
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
