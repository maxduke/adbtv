import Foundation

let adbTVLocalizationBundle = Bundle.module

// UI text lives in the package bundle, including text built outside SwiftUI.
// Format arguments are values, so file names and device-supplied text stay verbatim.
func adbTVLocalized(_ key: String, _ arguments: String..., bundle: Bundle = adbTVLocalizationBundle) -> String {
    let format = bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: arguments.map { $0 as CVarArg })
}
