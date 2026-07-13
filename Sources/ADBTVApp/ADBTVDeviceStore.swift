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

    public func loadDevices() -> ADBTVDeviceStoreLoadResult {
        guard let data = userDefaults.data(forKey: key) else {
            return ADBTVDeviceStoreLoadResult(devices: [])
        }

        let decoder = JSONDecoder()
        do {
            return ADBTVDeviceStoreLoadResult(
                devices: try decoder.decode([ADBTVDeviceSummary].self, from: data)
            )
        } catch let archiveError {
            guard let archive = try? JSONSerialization.jsonObject(with: data),
                  let records = archive as? [Any] else {
                return ADBTVDeviceStoreLoadResult(
                    devices: [],
                    failureDescription: String(describing: archiveError)
                )
            }

            var devices: [ADBTVDeviceSummary] = []
            var rejectedRecordCount = 0
            for record in records {
                guard JSONSerialization.isValidJSONObject(record),
                      let recordData = try? JSONSerialization.data(withJSONObject: record),
                      let device = try? decoder.decode(ADBTVDeviceSummary.self, from: recordData) else {
                    rejectedRecordCount += 1
                    continue
                }
                devices.append(device)
            }

            return ADBTVDeviceStoreLoadResult(
                devices: devices,
                rejectedRecordCount: rejectedRecordCount,
                failureDescription: rejectedRecordCount > 0
                    ? String(describing: archiveError)
                    : nil
            )
        }
    }

    public func saveDevices(_ devices: [ADBTVDeviceSummary]) throws {
        let data = try JSONEncoder().encode(devices)
        userDefaults.set(data, forKey: key)
    }
}

public struct ADBTVDeviceStoreLoadResult: Equatable, Sendable {
    public var devices: [ADBTVDeviceSummary]
    public var rejectedRecordCount: Int
    public var failureDescription: String?

    public init(
        devices: [ADBTVDeviceSummary],
        rejectedRecordCount: Int = 0,
        failureDescription: String? = nil
    ) {
        self.devices = devices
        self.rejectedRecordCount = rejectedRecordCount
        self.failureDescription = failureDescription
    }

    public var hasFailures: Bool {
        rejectedRecordCount > 0 || failureDescription != nil
    }
}
