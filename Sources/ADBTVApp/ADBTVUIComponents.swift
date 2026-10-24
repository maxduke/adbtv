import ADBClientCore
import SwiftUI

// Prominent controls keep a white foreground in both appearances. The text/link
// accent is brighter in dark mode and must not be used as their fill.
enum ADBTVControlColors {
    static let actionFill = Color("ActionColor", bundle: .module)
}

extension View {
    func adbTVProminentButton() -> some View {
        buttonStyle(.borderedProminent)
            .tint(ADBTVControlColors.actionFill)
            .foregroundStyle(Color.white)
    }

    func adbTVAddressInput() -> some View {
#if os(iOS)
        autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
#else
        autocorrectionDisabled()
#endif
    }

    func adbTVNumericInput() -> some View {
#if os(iOS)
        autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.numberPad)
#else
        autocorrectionDisabled()
#endif
    }
}

struct ADBTVFormField<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct ADBTVLabeledValue: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var title: String
    var value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                    Text(value)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LabeledContent(title) {
                    Text(value)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ADBTVAdaptiveLabeledContentStyle: LabeledContentStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                configuration.label
                configuration.content
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            LabeledContent(configuration)
                .labeledContentStyle(.automatic)
        }
    }
}

struct DiagnosticDisclosure: View {
    var diagnosticDetail: DiagnosticDetail

    var body: some View {
        DisclosureGroup(adbTVLocalized("Technical Details")) {
            ScrollView([.horizontal, .vertical]) {
                Text(diagnosticDetail.formattedDescription)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }
}
