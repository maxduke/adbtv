import ADBClientCore
import Foundation

enum ADBTVConfigurationBackupError: Error, Equatable {
    case invalidBackup, unsupportedVersion, tooLarge, invalidSavedData, changedLibrary, noSelection, busy

    var userMessage: String {
        switch self {
        case .invalidBackup: return adbTVLocalized("This is not a valid ADB TV configuration backup.")
        case .unsupportedVersion: return adbTVLocalized("This backup uses an unsupported format version.")
        case .tooLarge: return adbTVLocalized("Backups support up to 100 devices and a 1 MiB file.")
        case .invalidSavedData: return adbTVLocalized("Saved configuration could not be read safely. Existing data was preserved.")
        case .changedLibrary: return adbTVLocalized("Saved devices or preferences changed. Import the backup again to review the current result.")
        case .noSelection: return adbTVLocalized("Select at least one new device to restore.")
        case .busy: return adbTVLocalized("Another TV operation is in progress. Try again when it finishes.")
        }
    }
}

struct ADBTVConfigurationBackup: Codable, Equatable, Sendable {
    static let maximumByteCount = 1024 * 1024
    static let maximumDeviceCount = 100
    static let formatName = "adbtv.configuration"

    var format = Self.formatName
    var version = 1
    var devices: [Device]

    struct Device: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var displayName: String
        var model: String?
        var connection: Connection
        var quickLaunch: [ADBTVQuickLaunchStore.UserApps]

        init(_ device: ADBTVDeviceSummary, quickLaunch: [ADBTVQuickLaunchStore.UserApps]) throws {
            id = device.id
            displayName = device.displayName
            model = device.model
            connection = try Connection(device.connection)
            self.quickLaunch = quickLaunch
        }

        var summary: ADBTVDeviceSummary {
            switch connection.kind {
            case .hostPort:
                return ADBTVDeviceSummary(id: id, displayName: displayName, host: connection.host ?? "", port: connection.port ?? 0, model: model)
            case .bonjour:
                return ADBTVDeviceSummary(id: id, displayName: displayName, bonjourService: ADBDiscoveredService(
                    serviceName: connection.serviceName ?? "",
                    serviceType: ADBWirelessDebuggingServiceKind.connect.bonjourType,
                    domain: connection.domain ?? ""
                ), model: model)
            }
        }
    }

    struct Connection: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case hostPort, bonjour }
        enum Endpoint: Hashable, Sendable {
            case hostPort(String, Int)
            case bonjour(String, String)
        }
        var kind: Kind
        var host: String?
        var port: Int?
        var serviceName: String?
        var domain: String?

        init(_ connection: ADBTVDeviceConnection) throws {
            switch connection {
            case let .hostPort(host, port):
                kind = .hostPort
                self.host = host
                self.port = port
            case .bonjour(let service):
                guard service.kind == .connect else { throw ADBTVConfigurationBackupError.invalidBackup }
                kind = .bonjour
                serviceName = service.serviceName
                domain = service.domain
            }
        }

        var endpointKey: Endpoint {
            switch kind {
            case .hostPort: return .hostPort(host?.lowercased() ?? "", port ?? 0)
            case .bonjour:
                return .bonjour(serviceName?.lowercased() ?? "", domain?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "")
            }
        }

        func validate() throws {
            switch kind {
            case .hostPort:
                guard let host, Self.validAddress(host), let port, (1...65535).contains(port),
                      serviceName == nil, domain == nil else { throw ADBTVConfigurationBackupError.invalidBackup }
            case .bonjour:
                guard let serviceName, Self.validText(serviceName, maximum: 255),
                      let domain, Self.validAddress(domain), host == nil, port == nil else {
                    throw ADBTVConfigurationBackupError.invalidBackup
                }
            }
        }

        private static func validAddress(_ value: String) -> Bool {
            validText(value, maximum: 255)
                && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && !value.contains(where: { "/\\@?#".contains($0) })
        }

        static func validText(_ value: String, maximum: Int = 1024) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.utf8.count <= maximum
                && value.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }

    func validate() throws {
        guard format == Self.formatName else { throw ADBTVConfigurationBackupError.invalidBackup }
        guard version == 1 else { throw ADBTVConfigurationBackupError.unsupportedVersion }
        guard devices.count <= Self.maximumDeviceCount else { throw ADBTVConfigurationBackupError.tooLarge }
        guard Set(devices.map(\.id)).count == devices.count,
              Set(devices.map { $0.connection.endpointKey }).count == devices.count else {
            throw ADBTVConfigurationBackupError.invalidBackup
        }
        for device in devices {
            guard Connection.validText(device.displayName),
                  device.model.map({ Connection.validText($0) }) ?? true else {
                throw ADBTVConfigurationBackupError.invalidBackup
            }
            try device.connection.validate()
            _ = try ADBTVQuickLaunchStore.encodedArchive(device.quickLaunch)
        }
    }

    func encoded() throws -> Data {
        try validate()
        var minimumByteCount = 0
        for device in devices {
            minimumByteCount += try JSONEncoder().encode(device).count
            guard minimumByteCount <= Self.maximumByteCount else { throw ADBTVConfigurationBackupError.tooLarge }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumByteCount else { throw ADBTVConfigurationBackupError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumByteCount else { throw ADBTVConfigurationBackupError.tooLarge }
        do {
            try validateShape(JSONSerialization.jsonObject(with: data))
            let backup = try JSONDecoder().decode(Self.self, from: data)
            try backup.validate()
            return backup
        } catch let error as ADBTVConfigurationBackupError { throw error }
        catch { throw ADBTVConfigurationBackupError.invalidBackup }
    }

    static func read(from url: URL) async throws -> Self {
        guard url.isFileURL else { throw ADBTVConfigurationBackupError.invalidBackup }
#if os(iOS) || os(macOS)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
#endif
        try Task.checkCancellation()
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ADBTVConfigurationBackupError.invalidBackup
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumByteCount {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(64 * 1024, maximumByteCount + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        try Task.checkCancellation()
        return try decode(data)
    }

    private static func validateShape(_ value: Any) throws {
        func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
            guard let result = value as? [String: Any], Set(result.keys).isSubset(of: keys) else {
                throw ADBTVConfigurationBackupError.invalidBackup
            }
            return result
        }
        let root = try object(value, keys: ["format", "version", "devices"])
        guard let devices = root["devices"] as? [Any] else { throw ADBTVConfigurationBackupError.invalidBackup }
        guard devices.count <= maximumDeviceCount else { throw ADBTVConfigurationBackupError.tooLarge }
        for value in devices {
            let device = try object(value, keys: ["id", "displayName", "model", "connection", "quickLaunch"])
            guard let rawConnection = device["connection"], let users = device["quickLaunch"] as? [Any] else {
                throw ADBTVConfigurationBackupError.invalidBackup
            }
            let connection = try object(rawConnection, keys: ["kind", "host", "port", "serviceName", "domain"])
            let keys: Set<String> = connection["kind"] as? String == "hostPort"
                ? ["kind", "host", "port"] : ["kind", "serviceName", "domain"]
            guard Set(connection.keys).isSubset(of: keys) else { throw ADBTVConfigurationBackupError.invalidBackup }
            for value in users {
                let user = try object(value, keys: ["userID", "apps"])
                guard let apps = user["apps"] as? [Any] else { throw ADBTVConfigurationBackupError.invalidBackup }
                for app in apps { _ = try object(app, keys: ["packageName", "displayName"]) }
            }
        }
    }
}

struct ADBTVConfigurationRestorePlan: Sendable {
    struct Row: Identifiable, Sendable {
        let record: ADBTVConfigurationBackup.Device
        let alreadySaved: Bool
        var id: UUID { record.id }
        fileprivate init(record: ADBTVConfigurationBackup.Device, alreadySaved: Bool) {
            self.record = record
            self.alreadySaved = alreadySaved
        }
    }
    let existingDevices: [ADBTVDeviceSummary]
    let rows: [Row]
    var newDeviceIDs: Set<UUID> { Set(rows.filter { !$0.alreadySaved }.map(\.id)) }
    fileprivate init(existingDevices: [ADBTVDeviceSummary], rows: [Row]) {
        self.existingDevices = existingDevices
        self.rows = rows
    }
}

struct ADBTVConfigurationRestoreReport: Sendable {
    let devices: [ADBTVDeviceSummary]
    let addedCount: Int
    let skippedCount: Int
}

struct ADBTVConfigurationBackupStore {
    let deviceStore: ADBTVDeviceStore
    private var quickLaunch: ADBTVQuickLaunchStore { ADBTVQuickLaunchStore(userDefaults: deviceStore.userDefaults) }

    func export() throws -> Data {
        do {
            let devices = try currentDevices()
            guard devices.count <= ADBTVConfigurationBackup.maximumDeviceCount else { throw ADBTVConfigurationBackupError.tooLarge }
            var records: [ADBTVConfigurationBackup.Device] = []
            var minimumByteCount = 0
            for device in devices {
                let record = try ADBTVConfigurationBackup.Device(device, quickLaunch: quickLaunch.allUsers(deviceID: device.id))
                minimumByteCount += try JSONEncoder().encode(record).count
                guard minimumByteCount <= ADBTVConfigurationBackup.maximumByteCount else { throw ADBTVConfigurationBackupError.tooLarge }
                records.append(record)
            }
            return try ADBTVConfigurationBackup(devices: records).encoded()
        } catch ADBTVConfigurationBackupError.tooLarge { throw ADBTVConfigurationBackupError.tooLarge }
        catch { throw ADBTVConfigurationBackupError.invalidSavedData }
    }

    func preview(_ backup: ADBTVConfigurationBackup) throws -> ADBTVConfigurationRestorePlan {
        try backup.validate()
        let existing = try currentDevices()
        let ids = Set(existing.map(\.id))
        let endpoints = try Set(existing.map { try ADBTVConfigurationBackup.Connection($0.connection).endpointKey })
        return ADBTVConfigurationRestorePlan(existingDevices: existing, rows: backup.devices.map {
            .init(record: $0, alreadySaved: ids.contains($0.id) || endpoints.contains($0.connection.endpointKey))
        })
    }

    @MainActor
    func restore(
        _ plan: ADBTVConfigurationRestorePlan,
        selectedIDs: Set<UUID>,
        persistDevices: (([ADBTVDeviceSummary]) throws -> Void)? = nil
    ) throws -> ADBTVConfigurationRestoreReport {
        guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: plan.newDeviceIDs) else {
            throw ADBTVConfigurationBackupError.noSelection
        }
        guard try currentDevices() == plan.existingDevices else { throw ADBTVConfigurationBackupError.changedLibrary }
        let selected = plan.rows.filter { selectedIDs.contains($0.id) }.map(\.record)
        // Complete all validation/encoding before staging any preferences.
        try ADBTVConfigurationBackup(devices: selected).validate()
        let merged = plan.existingDevices + selected.map(\.summary)
        _ = try JSONEncoder().encode(merged)
        for record in selected {
            _ = try ADBTVQuickLaunchStore.encodedArchive(record.quickLaunch)
            if quickLaunch.hasSavedApps(deviceID: record.id) {
                let orphan = try quickLaunch.allUsers(deviceID: record.id).sorted { $0.userID < $1.userID }
                guard orphan == record.quickLaunch.sorted(by: { $0.userID < $1.userID }) else {
                    throw ADBTVConfigurationBackupError.changedLibrary
                }
            }
        }
        var insertedKeys: [UUID] = []
        do {
            for record in selected where !quickLaunch.hasSavedApps(deviceID: record.id) {
                try quickLaunch.restoreNewArchive(record.quickLaunch, deviceID: record.id)
                if !record.quickLaunch.isEmpty { insertedKeys.append(record.id) }
            }
            try (persistDevices ?? deviceStore.saveDevices)(merged)
        } catch {
            for id in insertedKeys { quickLaunch.removeDevice(id) }
            throw error
        }
        return ADBTVConfigurationRestoreReport(devices: merged, addedCount: selected.count, skippedCount: plan.rows.count - selected.count)
    }

    private func currentDevices() throws -> [ADBTVDeviceSummary] {
        if deviceStore.userDefaults.object(forKey: deviceStore.key) != nil,
           deviceStore.userDefaults.data(forKey: deviceStore.key) == nil {
            throw ADBTVConfigurationBackupError.invalidSavedData
        }
        let result = deviceStore.loadDevices()
        guard !result.hasFailures else { throw ADBTVConfigurationBackupError.invalidSavedData }
        guard Set(result.devices.map(\.id)).count == result.devices.count else { throw ADBTVConfigurationBackupError.invalidSavedData }
        // Existing devices need not fit one export, but every connection must be unambiguous.
        let keys = try result.devices.map { device -> ADBTVConfigurationBackup.Connection.Endpoint in
            let connection = try ADBTVConfigurationBackup.Connection(device.connection)
            try connection.validate()
            return connection.endpointKey
        }
        guard Set(keys).count == keys.count else { throw ADBTVConfigurationBackupError.invalidSavedData }
        return result.devices
    }
}
