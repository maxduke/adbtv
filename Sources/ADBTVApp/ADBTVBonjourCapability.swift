import Foundation
#if canImport(Security)
import Security
#endif

struct ADBTVBonjourCapability: Equatable, Sendable {
    static let multicastEntitlement = "com.apple.developer.networking.multicast"

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
            isAvailable: hasEffectiveMulticastEntitlement,
            automaticallyStartsDiscovery: automaticallyStartsDiscovery
        )
    }

    static func isEnabled(entitlementValue: Any?) -> Bool {
        (entitlementValue as? Bool) == true
    }

    private static var hasEffectiveMulticastEntitlement: Bool {
#if canImport(Security)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  multicastEntitlement as CFString,
                  nil
              ) else {
            return false
        }
        return isEnabled(entitlementValue: value)
#else
        return false
#endif
    }
}
