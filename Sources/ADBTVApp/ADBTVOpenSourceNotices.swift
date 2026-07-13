import Foundation

enum ADBTVOpenSourceNotices {
    static let resourceName = "OpenSourceNotices"
    static let resourceExtension = "txt"

    static var text: String {
        (try? loadBundledText()) ?? "Open source notices are unavailable in this build."
    }

    static func loadBundledText() throws -> String {
        guard let resourceURL = Bundle.module.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        return try String(contentsOf: resourceURL, encoding: .utf8)
    }
}
