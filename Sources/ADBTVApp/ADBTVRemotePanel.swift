import ADBClientCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RemoteActionsPanel<QuickLaunch: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var status: ADBTVRemoteStatus
    var text: Binding<String>
    var canSendText: Bool
    var deviceOperationInProgress: Bool
    var unicodeHelperInstallStatus: ADBTVInstallStatus?
    var send: (ADBTVRemoteAction) -> Void
    var sendRepeat: (ADBTVRemoteAction) -> Void
    var sendFromKeyboard: (ADBTVRemoteAction) -> Void
    var sendText: () -> Void
    var startSession: () -> Void
    var stopSession: () -> Void
    var retrySession: () -> Void
    var cancelRemoteOperation: () -> Void
    var installUnicodeInputHelper: () -> Void
    @ViewBuilder var quickLaunch: () -> QuickLaunch

    @State private var isMediaControlsExpanded = ProcessInfo.processInfo.arguments.contains(
        "--ui-media-expanded"
    )
    @FocusState private var focusedControl: FocusedControl?
    @ScaledMetric(relativeTo: .title3) private var selectButtonDiameter: CGFloat = 76
    @ScaledMetric(relativeTo: .title3) private var remoteSymbolSize: CGFloat = 20

    private enum FocusedControl: Hashable {
        case remote
        case text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if status.showsPriorityFeedback {
                RemoteStatusView(
                    status: status,
                    retry: retrySession,
                    cancel: cancelRemoteOperation
                )
            }

            if !dynamicTypeSize.isAccessibilitySize {
                quickLaunch()
            }

            VStack(spacing: 16) {
                HStack {
                    roundButton(.power, systemImage: "power", foregroundStyle: .red)
                    Spacer()
                    roundButton(.menu, systemImage: "list.bullet")
                    Spacer()
                    roundButton(.home, systemImage: "house.fill")
                }

                directionalPad

                RemoteControlButton(action: { sendFromControl(.back) }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: min(remoteSymbolSize, 28), weight: .semibold))
                        .frame(width: 152, height: dynamicTypeSize.isAccessibilitySize ? 60 : 44)
                        .background(controlBackground, in: Capsule())
                }
                .accessibilityLabel(adbTVLocalized("Back"))

                ViewThatFits(in: .horizontal) {
                    HStack {
                        roundButton(.volumeDown, systemImage: "speaker.minus.fill")
                        Spacer()
                        roundButton(.volumeMute, systemImage: "speaker.slash.fill")
                        Spacer()
                        roundButton(.settings, systemImage: "gearshape.fill")
                        Spacer()
                        roundButton(.volumeUp, systemImage: "speaker.plus.fill")
                    }
                    VStack(spacing: 12) {
                        HStack {
                            roundButton(.volumeDown, systemImage: "speaker.minus.fill")
                            Spacer()
                            roundButton(.volumeUp, systemImage: "speaker.plus.fill")
                        }
                        HStack {
                            roundButton(.volumeMute, systemImage: "speaker.slash.fill")
                            Spacer()
                            roundButton(.settings, systemImage: "gearshape.fill")
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .disabled(
                scenePhase != .active
                    || status.remoteActionsUnavailable
                    || deviceOperationInProgress
            )

            if dynamicTypeSize.isAccessibilitySize {
                quickLaunch()
            }

            Divider()

            DisclosureGroup(isExpanded: $isMediaControlsExpanded) {
                mediaControls
                    .padding(.top, 12)
            } label: {
                Label(adbTVLocalized("Media Controls"), systemImage: "play.rectangle")
                    .font(.headline)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(adbTVLocalized("Text Input"))
                    .font(.headline)

                HStack(spacing: 8) {
                    TextField(adbTVLocalized("Type text to send"), text: text)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedControl, equals: .text)
                        .disabled(deviceOperationInProgress || status.remoteActionsUnavailable)
                    Button {
                        sendText()
                    } label: {
                        Label(adbTVLocalized("Send Text"), systemImage: "paperplane.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: min(remoteSymbolSize, 28), weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .adbTVProminentButton()
                    .disabled(!canSendText || status.remoteActionsUnavailable)
                    .accessibilityLabel(adbTVLocalized("Send Text"))
                }

                if text.wrappedValue.unicodeScalars.contains(where: { !$0.isASCII }) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            unicodeHelperLabel
                            Spacer(minLength: 8)
                            unicodeHelperButton
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            unicodeHelperLabel
                            unicodeHelperButton
                        }
                    }

                    if let unicodeHelperInstallStatus {
                        InstallStatusView(status: unicodeHelperInstallStatus)
                    }
                }
            }

            if !status.showsPriorityFeedback {
                RemoteStatusView(
                    status: status,
                    retry: retrySession,
                    cancel: cancelRemoteOperation
                )
            }
        }
        .focusable()
        .focused($focusedControl, equals: .remote)
        .focusEffectDisabled()
        .onKeyPress(
            keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape],
            phases: [.down, .repeat]
        ) { press in
            handleKeyPress(press)
        }
        .onAppear {
            focusedControl = .remote
            if scenePhase == .active {
                startSession()
            }
        }
        .onDisappear(perform: stopSession)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                startSession()
            case .background:
                stopSession()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private var directionalPad: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            let selectSize = min(selectButtonDiameter, min(120, size * 0.38))
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.10))

                directionButton(.up, systemImage: "chevron.up")
                    .position(x: size / 2, y: size * 0.18)
                directionButton(.left, systemImage: "chevron.left")
                    .position(x: size * 0.18, y: size / 2)
                directionButton(.right, systemImage: "chevron.right")
                    .position(x: size * 0.82, y: size / 2)
                directionButton(.down, systemImage: "chevron.down")
                    .position(x: size / 2, y: size * 0.82)

                RemoteControlButton(action: { sendFromControl(.select) }) {
                    Text(adbTVLocalized("OK"))
                        .font(.title3.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(8)
                        .frame(width: selectSize, height: selectSize)
                        .background(ADBTVControlColors.actionFill, in: Circle())
                }
                .foregroundStyle(Color.white)
                .accessibilityLabel(adbTVLocalized("Select"))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 248)
        .frame(maxWidth: .infinity)
    }

    private var controlBackground: Color {
        Color.secondary.opacity(0.14)
    }

    private var mediaControls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 12)],
                    spacing: 12
                ) {
                    mediaButton(.mediaPrevious, systemImage: "backward.end.fill", title: adbTVLocalized("Prev"))
                    mediaButton(.mediaRewind, systemImage: "backward.fill", title: adbTVLocalized("Rew"))
                    mediaButton(.mediaPlayPause, systemImage: "playpause.fill", title: adbTVLocalized("Play"))
                    mediaButton(.mediaFastForward, systemImage: "forward.fill", title: adbTVLocalized("FF"))
                    mediaButton(.mediaNext, systemImage: "forward.end.fill", title: adbTVLocalized("Next"))
                    mediaButton(.mediaStop, systemImage: "stop.fill", title: adbTVLocalized("Stop"), tint: .red)
                    mediaButton(.enter, systemImage: "return", title: adbTVLocalized("Enter"))
                    mediaButton(.delete, systemImage: "delete.left.fill", title: adbTVLocalized("Delete"))
                    mediaButton(.tab, systemImage: "arrow.right.to.line", title: adbTVLocalized("Tab"))
                }
            } else {
                defaultMediaControls
            }
        }
        .disabled(
            scenePhase != .active
                || status.remoteActionsUnavailable
                || deviceOperationInProgress
        )
    }

    private var defaultMediaControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                mediaButton(.mediaPrevious, systemImage: "backward.end.fill", title: adbTVLocalized("Prev"))
                Spacer(minLength: 4)
                mediaButton(.mediaRewind, systemImage: "backward.fill", title: adbTVLocalized("Rew"))
                Spacer(minLength: 4)
                mediaButton(.mediaPlayPause, systemImage: "playpause.fill", title: adbTVLocalized("Play"))
                Spacer(minLength: 4)
                mediaButton(.mediaFastForward, systemImage: "forward.fill", title: adbTVLocalized("FF"))
                Spacer(minLength: 4)
                mediaButton(.mediaNext, systemImage: "forward.end.fill", title: adbTVLocalized("Next"))
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                mediaButton(.mediaStop, systemImage: "stop.fill", title: adbTVLocalized("Stop"), tint: .red)
                Spacer(minLength: 12)
                mediaButton(.enter, systemImage: "return", title: adbTVLocalized("Enter"))
                Spacer(minLength: 12)
                mediaButton(.delete, systemImage: "delete.left.fill", title: adbTVLocalized("Delete"))
                Spacer(minLength: 12)
                mediaButton(.tab, systemImage: "arrow.right.to.line", title: adbTVLocalized("Tab"))
                Spacer(minLength: 0)
            }
        }
    }

    private func mediaButton(
        _ action: ADBTVRemoteAction,
        systemImage: String,
        title: String,
        tint: Color = .primary
    ) -> some View {
        RemoteControlButton(action: { sendFromControl(action) }) {
            mediaButtonLabel(systemImage: systemImage, title: title, tint: tint)
        }
        .accessibilityLabel(action.displayTitle)
    }

    @ViewBuilder
    private func mediaButtonLabel(
        systemImage: String,
        title: String,
        tint: Color
    ) -> some View {
        let label = VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 24)
            Text(title)
                .font(.caption2)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
        .foregroundStyle(tint)

        if dynamicTypeSize.isAccessibilitySize {
            label
                .frame(maxWidth: .infinity, minHeight: 92)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 8))
        } else {
            label
                .frame(width: 54, height: 58)
                .background(controlBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func directionButton(
        _ action: ADBTVRemoteAction,
        systemImage: String
    ) -> some View {
        RemoteControlButton(
            action: { sendFromControl(action) },
            repeatAction: { sendRepeat(action) }
        ) {
            Image(systemName: systemImage)
                .font(.system(size: min(remoteSymbolSize, 28), weight: .bold))
                .frame(
                    width: dynamicTypeSize.isAccessibilitySize ? 60 : 52,
                    height: dynamicTypeSize.isAccessibilitySize ? 60 : 52
                )
                .contentShape(Circle())
        }
        .accessibilityLabel(action.displayTitle)
    }

    private func roundButton(
        _ action: ADBTVRemoteAction,
        systemImage: String,
        foregroundStyle: Color = .primary
    ) -> some View {
        RemoteControlButton(
            action: { sendFromControl(action) },
            repeatAction: action == .volumeDown || action == .volumeUp
                ? { sendRepeat(action) }
                : nil
        ) {
            Image(systemName: systemImage)
                .font(.system(size: min(remoteSymbolSize, 28), weight: .semibold))
                .foregroundStyle(foregroundStyle)
                .frame(
                    width: dynamicTypeSize.isAccessibilitySize ? 60 : 50,
                    height: dynamicTypeSize.isAccessibilitySize ? 60 : 50
                )
                .background(controlBackground, in: Circle())
        }
        .accessibilityLabel(action.displayTitle)
    }

    private var unicodeHelperLabel: some View {
        Label(
            adbTVLocalized("Chinese and other Unicode text uses the optional TV input helper."),
            systemImage: "character.cursor.ibeam"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var unicodeHelperButton: some View {
        Button {
            installUnicodeInputHelper()
        } label: {
            Label(adbTVLocalized("Install Input Helper"), systemImage: "keyboard")
        }
        .buttonStyle(.bordered)
        .disabled(deviceOperationInProgress || status.remoteActionsUnavailable)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard focusedControl != .text else {
            return .ignored
        }

        let action: ADBTVRemoteAction
        switch press.key {
        case .upArrow:
            action = .up
        case .downArrow:
            action = .down
        case .leftArrow:
            action = .left
        case .rightArrow:
            action = .right
        case .return:
            action = .select
        case .escape:
            action = .back
        default:
            return .ignored
        }

        if press.phase == .repeat {
            if action == .up || action == .down || action == .left || action == .right {
                sendRepeat(action)
            }
            return .handled
        }
        sendFromKeyboard(action)
        return .handled
    }

    private func sendFromControl(_ action: ADBTVRemoteAction) {
        focusedControl = .remote
        send(action)
    }

}

private struct RemoteControlButton<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    var action: () -> Void
    var repeatAction: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        label()
            .contentShape(Rectangle())
            .opacity(isEnabled ? (isPressed ? 0.65 : 1) : 0.45)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPress() }
                    .onEnded { _ in endPress() }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    endPress()
                }
            }
            .onDisappear(perform: endPress)
    }

    private func beginPress() {
        guard isEnabled, !isPressed else {
            return
        }
        isPressed = true
        action()
        guard let repeatAction else {
            return
        }
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            for _ in 0..<62 where !Task.isCancelled {
                repeatAction()
                try? await Task.sleep(for: .milliseconds(125))
            }
        }
    }

    private func endPress() {
        isPressed = false
        repeatTask?.cancel()
        repeatTask = nil
    }
}

private struct RemoteStatusView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var status: ADBTVRemoteStatus
    var retry: () -> Void
    var cancel: () -> Void

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .connecting:
            connectionStatus(adbTVLocalized("Connecting to TV"))
        case .reconnecting:
            connectionStatus(adbTVLocalized("Reconnecting to TV"))
        case .catchingUp:
            Label(adbTVLocalized("Remote is catching up"), systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
        case .connectionFailed(let userMessage, let diagnosticDetail):
            VStack(alignment: .leading, spacing: 10) {
                Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button(action: retry) {
                    Label(adbTVLocalized("Retry Connection"), systemImage: "arrow.clockwise")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .adbTVProminentButton()
                DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
            }
        case .sending(let action):
            sendingStatus(adbTVLocalized("Sending %@", String(describing: action.displayTitle)))
        case .sendingText:
            sendingStatus(adbTVLocalized("Sending text"))
        case .sent(let action):
            Label(adbTVLocalized("Sent %@", String(describing: action.displayTitle)), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .sentText:
            Label(adbTVLocalized("Text sent"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(_, let userMessage, let diagnosticDetail):
            RemoteFailureView(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        case .failedText(let userMessage, let diagnosticDetail):
            RemoteFailureView(
                userMessage: userMessage,
                diagnosticDetail: diagnosticDetail
            )
        }
    }

    private func connectionStatus(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private func sendingStatus(_ title: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    connectionStatus(title)
                    cancelButton
                }
            } else {
                HStack(spacing: 10) {
                    connectionStatus(title)
                    Spacer(minLength: 8)
                    cancelButton
                }
            }
        }
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: cancel) {
            Label(adbTVLocalized("Cancel"), systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
    }
}

private struct RemoteFailureView: View {
    var userMessage: String
    var diagnosticDetail: DiagnosticDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(userMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            DiagnosticDisclosure(diagnosticDetail: diagnosticDetail)
        }
    }
}

extension ADBTVRemoteAction {
    var displayTitle: String {
        switch self {
        case .home:
            return adbTVLocalized("Home")
        case .back:
            return adbTVLocalized("Back")
        case .up:
            return adbTVLocalized("Up")
        case .down:
            return adbTVLocalized("Down")
        case .left:
            return adbTVLocalized("Left")
        case .right:
            return adbTVLocalized("Right")
        case .select:
            return adbTVLocalized("OK")
        case .settings:
            return adbTVLocalized("Settings")
        case .menu:
            return adbTVLocalized("Menu")
        case .volumeUp:
            return adbTVLocalized("Volume Up")
        case .volumeDown:
            return adbTVLocalized("Volume Down")
        case .volumeMute:
            return adbTVLocalized("Mute")
        case .power:
            return adbTVLocalized("Power")
        case .mediaPrevious:
            return adbTVLocalized("Previous")
        case .mediaRewind:
            return adbTVLocalized("Rewind")
        case .mediaPlayPause:
            return adbTVLocalized("Play or Pause")
        case .mediaFastForward:
            return adbTVLocalized("Fast Forward")
        case .mediaNext:
            return adbTVLocalized("Next")
        case .mediaStop:
            return adbTVLocalized("Stop")
        case .enter:
            return adbTVLocalized("Enter")
        case .delete:
            return adbTVLocalized("Delete")
        case .tab:
            return adbTVLocalized("Tab")
        }
    }
}
