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
        if ProcessInfo.processInfo.arguments.contains("--ui-about") {
            ADBTVRootView(
                model: ADBTVAppModel(),
                automaticallyStartsDiscovery: false,
                bonjourDiscoveryAvailable: false,
                initiallyPresentsAbout: true
            )
        } else if ProcessInfo.processInfo.arguments.contains("--ui-library") {
            ADBTVRootView(
                model: ADBTVAppModel(),
                automaticallyStartsDiscovery: false,
                bonjourDiscoveryAvailable: false
            )
        } else if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            ADBTVRootView(
                model: .preview,
                automaticallyStartsDiscovery: false
            )
        } else {
            ADBTVRootView()
        }
#else
        ADBTVRootView()
#endif
    }
}
