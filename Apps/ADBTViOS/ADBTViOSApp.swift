import ADBTVApp
import SwiftUI

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
                isLandscape: ProcessInfo.processInfo.arguments.contains("--ui-landscape")
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
    var isLandscape: Bool

    var body: some View {
        GeometryReader { geometry in
            if isLandscape {
                rootView
                    .frame(width: geometry.size.height, height: geometry.size.width)
                    .rotationEffect(.degrees(-90))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            } else {
                rootView
            }
        }
    }

    private var rootView: some View {
        ADBTVRootView(
            model: .preview,
            automaticallyStartsDiscovery: false
        )
    }
}
#endif
