import ADBTVApp
import SwiftUI
#if DEBUG
import UIKit
#endif

@main
struct ADBTViOSApp: App {
    var body: some Scene {
        WindowGroup {
            appRoot
        }
    }

    @ViewBuilder
    private var appRoot: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            ADBTVPreviewRoot(
                orientation: ProcessInfo.processInfo.arguments.contains("--ui-landscape")
                    ? .landscapeLeft
                    : .portrait
            )
        } else {
            ADBTVRootView()
        }
#else
        ADBTVRootView()
#endif
    }
}

#if DEBUG
private struct ADBTVPreviewRoot: View {
    var orientation: UIInterfaceOrientationMask

    var body: some View {
        ADBTVRootView(
            model: .preview,
            automaticallyStartsDiscovery: false
        )
        .task {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else {
                return
            }
            try? await windowScene.requestGeometryUpdate(
                .iOS(interfaceOrientations: orientation)
            )
        }
    }
}
#endif
