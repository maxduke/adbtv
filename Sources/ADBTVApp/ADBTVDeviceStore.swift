import Foundation

public struct ADBTVDeviceStore {
    public var userDefaults: UserDefaults
    public var key: String

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = "ADBTV.savedDevices"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public func loadDevices() -> [ADBTVDeviceSummary] {
        guard let data = userDefaults.data(forKey: key) else {
            return []
        }

        return (try? JSONDecoder().decode([ADBTVDeviceSummary].self, from: data)) ?? []
    }

    public func saveDevices(_ devices: [ADBTVDeviceSummary]) throws {
        let data = try JSONEncoder().encode(devices)
        userDefaults.set(data, forKey: key)
    }
}
