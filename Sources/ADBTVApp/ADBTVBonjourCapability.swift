import Foundation

struct ADBTVBonjourCapability: Equatable, Sendable {
    static let configurationKey = "ADBTVBonjourDiscoveryEnabled"

    let isAvailable: Bool
    let automaticallyStartsDiscovery: Bool

    init(
        isAvailable: Bool,
        automaticallyStartsDiscovery: Bool? = nil
    ) {
        self.isAvailable = isAvailable
        self.automaticallyStartsDiscovery = isAvailable
            && (automaticallyStartsDiscovery ?? true)
    }

    static func current(
        automaticallyStartsDiscovery: Bool? = nil
    ) -> ADBTVBonjourCapability {
        ADBTVBonjourCapability(
            isAvailable: isEnabled(
                configurationValue: Bundle.main.object(
                    forInfoDictionaryKey: configurationKey
                )
            ),
            automaticallyStartsDiscovery: automaticallyStartsDiscovery
        )
    }

    static func isEnabled(configurationValue: Any?) -> Bool {
        if let value = configurationValue as? Bool {
            return value
        }
        guard let value = configurationValue as? String else {
            return false
        }
        return ["1", "true", "yes"].contains(value.lowercased())
    }
}
