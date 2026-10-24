import ADBClientCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ADBTVAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(adbTVLocalized("Version"), value: versionDescription)
                }

                Section(adbTVLocalized("Legal")) {
                    NavigationLink {
                        ADBTVOpenSourceNoticesView()
                    } label: {
                        Label(adbTVLocalized("Licenses & Notices"), systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle(adbTVLocalized("About ADB TV"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(adbTVLocalized("Close"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .help(adbTVLocalized("Close"))
                }
            }
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return build
        case (nil, nil):
            return adbTVLocalized("Unknown")
        }
    }
}

private struct ADBTVOpenSourceNoticesView: View {
    var body: some View {
        ScrollView {
            Text(ADBTVOpenSourceNotices.text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(adbTVLocalized("Licenses & Notices"))
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
