import ADBClientCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct APKInstallPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var installDraft: ADBTVInstallDraft
    var installURLString: Binding<String>
    var canInstall: Bool
    var deviceOperationInProgress: Bool
    var chooseAPK: () -> Void
    var install: () -> Void
    var cancelInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    chooseButton
                    installButton
                    if installDraft.status.canCancel {
                        cancelButton
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        chooseButton
                        installButton
                        if installDraft.status.canCancel {
                            cancelButton
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            chooseButton
                            installButton
                        }
                        if installDraft.status.canCancel {
                            cancelButton
                        }
                    }
                }
            }

            TextField(adbTVLocalized("App package URL"), text: installURLString)
                .adbTVAddressInput()
                .textFieldStyle(.roundedBorder)
                .disabled(installDraft.status.isRunning || deviceOperationInProgress)

            if !installURLString.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !installDraft.canPrepareInstallPackage {
                Label(adbTVLocalized("Enter a direct HTTP or HTTPS APK or APKM URL"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            if let package = installDraft.selectedPackage {
                ADBTVLabeledValue(adbTVLocalized("Package"), value: package.fileName)
                if let byteCount = package.byteCount {
                    ADBTVLabeledValue(adbTVLocalized("Size"), value: Self.formattedByteCount(byteCount))
                }
            } else if let url = installDraft.validatedURL {
                ADBTVLabeledValue(adbTVLocalized("Source"), value: url.absoluteString)
            }

            if installDraft.usesInsecureHTTP {
                Label(
                    adbTVLocalized("HTTP downloads are not protected in transit."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            InstallStatusView(status: installDraft.status)
        }
    }

    private var chooseButton: some View {
        Button {
            chooseAPK()
        } label: {
            Label(adbTVLocalized("Choose Package"), systemImage: "doc.badge.plus")
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .disabled(installDraft.status.isRunning || deviceOperationInProgress)
    }

    private var installButton: some View {
        Button {
            install()
        } label: {
            Label(adbTVLocalized("Install"), systemImage: "square.and.arrow.down")
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        }
        .adbTVProminentButton()
        .disabled(!canInstall || installDraft.status.isRunning || deviceOperationInProgress)
    }

    private var cancelButton: some View {
        Button(role: .cancel) {
            cancelInstall()
        } label: {
            Label(adbTVLocalized("Cancel"), systemImage: "xmark.circle")
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        }
        .buttonStyle(.bordered)
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

private struct InstallStatusView: View {
    var status: ADBTVInstallStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .ready:
            Label(adbTVLocalized("Ready to install"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .running(let phase):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                Label(statusTitle(for: phase), systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        case .downloading(let receivedByteCount, let totalByteCount):
            VStack(alignment: .leading, spacing: 8) {
                if let totalByteCount, totalByteCount > 0 {
                    ProgressView(value: progressFraction(receivedByteCount, totalByteCount))
                    Text(adbTVLocalized("%@ of %@ bytes", String(describing: receivedByteCount), String(describing: totalByteCount)))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text(adbTVLocalized("%@ bytes received", receivedByteCount.formatted()))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Label(adbTVLocalized("Downloading package"), systemImage: "arrow.down.doc")
                    .foregroundStyle(.secondary)
            }
        case .transferring(let sentByteCount, let totalByteCount):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: transferFraction(sentByteCount, totalByteCount))
                Label(adbTVLocalized("Transferring package"), systemImage: "arrow.up.doc")
                    .foregroundStyle(.secondary)
                Text(adbTVLocalized("%@ of %@ bytes", String(describing: sentByteCount), String(describing: totalByteCount)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .cancelling:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                Label(adbTVLocalized("Cancelling and cleaning up"), systemImage: "trash")
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            Label(adbTVLocalized("Installed"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .cancelled:
            Label(adbTVLocalized("Installation cancelled"), systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .cancelledWithCleanupFailure(let diagnosticDetail):
            VStack(alignment: .leading, spacing: 8) {
                Label(adbTVLocalized("Installation cancelled, but device cleanup failed."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        case .failed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 8) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        }
    }

    private func statusTitle(for phase: ADBAPKInstallPhase) -> String {
        switch phase {
        case .validatePackage:
            return adbTVLocalized("Validating package")
        case .prepareRemoteDirectory:
            return adbTVLocalized("Preparing device")
        case .transferPackage:
            return adbTVLocalized("Transferring package")
        case .installPackage:
            return adbTVLocalized("Installing")
        case .cleanup:
            return adbTVLocalized("Cleaning up")
        }
    }

    private func transferFraction(_ sentByteCount: Int, _ totalByteCount: Int) -> Double {
        progressFraction(Int64(sentByteCount), Int64(totalByteCount))
    }

    private func progressFraction(_ completedByteCount: Int64, _ totalByteCount: Int64) -> Double {
        guard totalByteCount > 0 else {
            return 1
        }

        return min(max(Double(completedByteCount) / Double(totalByteCount), 0), 1)
    }
}
