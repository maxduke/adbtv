import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

@MainActor
final class ADBTVConfigurationBackupTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var devices: ADBTVDeviceStore!
    private var pins: ADBTVQuickLaunchStore!
    private var store: ADBTVConfigurationBackupStore { .init(deviceStore: devices) }

    override func setUp() async throws {
        suite = "ADBTVConfigurationBackupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        devices = ADBTVDeviceStore(userDefaults: defaults)
        pins = ADBTVQuickLaunchStore(userDefaults: defaults)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testRoundTripPreservesDevicesUsersAndAppOrderWithoutUnrelatedData() async throws {
        let tv = device("Living Room", "tv.local")
        let bonjour = ADBTVDeviceSummary(displayName: "Bedroom", bonjourService: ADBDiscoveredService(
            serviceName: "adb-bedroom", serviceType: "_adb-tls-connect._tcp", domain: "local.", interfaceName: "en9"
        ), model: "Android TV")
        try devices.saveDevices([tv, bonjour])
        for index in [2, 0, 1] { try pins.pin(package(index), displayName: "电影 \(index) 100%", deviceID: tv.id, userID: 10) }
        try pins.pin(package(4), displayName: "Owner App", deviceID: tv.id, userID: 0)
        defaults.set("not part of the backup", forKey: "unrelated.setting")
        let data = try store.export()
        let backup = try ADBTVConfigurationBackup.decode(data)
        XCTAssertEqual(backup.devices.map(\.id), [tv.id, bonjour.id])
        XCTAssertEqual(backup.devices[0].quickLaunch.first { $0.userID == 10 }?.apps.map(\.packageName), [2, 0, 1].map { "com.example.app\($0)" })
        XCTAssertEqual(backup.devices[0].summary, tv)
        XCTAssertNil(backup.devices[1].summary.bonjourService?.interfaceName)
        XCTAssertEqual(backup.devices[1].summary.bonjourService?.serviceName, "adb-bedroom")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("unrelated"))
        XCTAssertFalse(text.contains("en9"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["format", "version", "devices"])
        XCTAssertEqual(try backup.encoded(), data)
    }

    func testRestoreIsSelectedOnlyAndNeverChangesExistingDeviceOrPins() async throws {
        let existing = device("Current name", "tv.local")
        try devices.saveDevices([existing])
        try pins.pin(package(0), displayName: "Current favorite", deviceID: existing.id, userID: 0)
        let originalPins = defaults.data(forKey: pinKey(existing.id))
        defaults.set("Keep", forKey: "unrelated.setting")
        var oldExisting = existing
        oldExisting.displayName = "Old name"
        oldExisting.connection = .hostPort(host: "old-address.local", port: 1234)
        let new = device("New TV", "new.local")
        let unchecked = device("Unchecked TV", "unchecked.local")
        let backup = try archive([oldExisting, new, unchecked], favorite: 3)
        let plan = try store.preview(backup)
        XCTAssertTrue(plan.rows[0].alreadySaved)
        let result = try store.restore(plan, selectedIDs: [new.id])
        XCTAssertEqual(result.devices, [existing, new])
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(devices.loadDevices().devices, [existing, new])
        XCTAssertEqual(defaults.data(forKey: pinKey(existing.id)), originalPins)
        XCTAssertEqual(try pins.apps(deviceID: new.id, userID: 10).first?.packageName, "com.example.app3")
        XCTAssertTrue(try pins.apps(deviceID: new.id, userID: 0).isEmpty)
        XCTAssertFalse(pins.hasSavedApps(deviceID: unchecked.id))
        XCTAssertEqual(defaults.string(forKey: "unrelated.setting"), "Keep")
    }

    func testEndpointDuplicatesAreSkippedAcrossIDsAndCase() async throws {
        let existing = device("Current", "TV.LOCAL")
        let service = ADBDiscoveredService(serviceName: "ADB-BED", serviceType: "_adb-tls-connect._tcp", domain: "LOCAL.")
        let bedroom = ADBTVDeviceSummary(displayName: "Bed", bonjourService: service)
        try devices.saveDevices([existing, bedroom])
        let duplicate = device("Backup", "tv.local")
        let duplicateService = ADBTVDeviceSummary(displayName: "Bed Backup", bonjourService: ADBDiscoveredService(
            serviceName: "adb-bed", serviceType: "_adb-tls-connect._tcp", domain: "local"
        ))
        let plan = try store.preview(archive([duplicate, duplicateService]))
        XCTAssertTrue(plan.newDeviceIDs.isEmpty)
        XCTAssertTrue(plan.rows.allSatisfy(\.alreadySaved))
        let data = defaults.data(forKey: devices.key)
        XCTAssertThrowsError(try store.restore(plan, selectedIDs: []))
        XCTAssertEqual(defaults.data(forKey: devices.key), data)
    }

    func testReimportAfterRepairRecognizesThePreservedUUID() async throws {
        let tv = device("TV", "before.local")
        let backup = try archive([tv], favorite: 1)
        _ = try store.restore(store.preview(backup), selectedIDs: [tv.id])
        var repaired = tv
        repaired.connection = .hostPort(host: "after.local", port: 4567)
        repaired.displayName = "New name"
        try devices.saveDevices([repaired])
        XCTAssertTrue(try store.preview(backup).newDeviceIDs.isEmpty)
        XCTAssertEqual(devices.loadDevices().devices, [repaired])
    }

    func testStalePreviewIsRejectedBeforeAnyPreferencesAreStaged() async throws {
        let tv = device("Backup", "new.local")
        let plan = try store.preview(archive([tv], favorite: 0))
        let other = device("Added in another window", "other.local")
        try devices.saveDevices([other])
        XCTAssertThrowsError(try store.restore(plan, selectedIDs: [tv.id])) {
            XCTAssertEqual($0 as? ADBTVConfigurationBackupError, .changedLibrary)
        }
        XCTAssertEqual(devices.loadDevices().devices, [other])
        XCTAssertFalse(pins.hasSavedApps(deviceID: tv.id))
    }

    func testChangedExistingPinsAreRetainedWhileAddingNewTV() async throws {
        let current = device("Current", "current.local")
        let new = device("New", "new.local")
        try devices.saveDevices([current])
        let plan = try store.preview(archive([new], favorite: 1))
        try pins.pin(package(4), displayName: "Added later", deviceID: current.id, userID: 0)
        let data = defaults.data(forKey: pinKey(current.id))
        _ = try store.restore(plan, selectedIDs: [new.id])
        XCTAssertEqual(defaults.data(forKey: pinKey(current.id)), data)
    }

    func testCommitFailureRollsBackOnlyNewlyStagedKeys() async throws {
        let existing = device("Existing", "existing.local")
        let first = device("First", "one.local")
        let second = device("Second", "two.local")
        try devices.saveDevices([existing])
        try pins.pin(package(0), displayName: nil, deviceID: existing.id, userID: 0)
        let beforeDevices = defaults.data(forKey: devices.key)
        let beforePins = defaults.data(forKey: pinKey(existing.id))
        let plan = try store.preview(archive([first, second], favorite: 1))
        XCTAssertThrowsError(try store.restore(plan, selectedIDs: [first.id, second.id], persistDevices: { _ in
            throw BackupTestError.failed
        }))
        XCTAssertEqual(defaults.data(forKey: devices.key), beforeDevices)
        XCTAssertEqual(defaults.data(forKey: pinKey(existing.id)), beforePins)
        XCTAssertFalse(pins.hasSavedApps(deviceID: first.id))
        XCTAssertFalse(pins.hasSavedApps(deviceID: second.id))
    }

    func testInterruptedRestoreAdoptsMatchingOrphanPreferencesWithoutRewriting() async throws {
        let tv = device("TV", "tv.local")
        try pins.pin(package(1), displayName: "App 1", deviceID: tv.id, userID: 10)
        let existing = defaults.data(forKey: pinKey(tv.id))
        let backup = try archive([tv], favorite: 1)
        _ = try store.restore(store.preview(backup), selectedIDs: [tv.id])
        XCTAssertEqual(defaults.data(forKey: pinKey(tv.id)), existing)
        XCTAssertEqual(devices.loadDevices().devices, [tv])
    }

    func testRollbackPreservesAnAdoptedOrphanAndRemovesOnlyNewStaging() async throws {
        let first = device("First", "one.local")
        let second = device("Second", "two.local")
        try pins.pin(package(1), displayName: "App 1", deviceID: first.id, userID: 10)
        let before = defaults.data(forKey: pinKey(first.id))
        let plan = try store.preview(archive([first, second], favorite: 1))
        XCTAssertThrowsError(try store.restore(plan, selectedIDs: [first.id, second.id], persistDevices: { _ in throw BackupTestError.failed }))
        XCTAssertEqual(defaults.data(forKey: pinKey(first.id)), before)
        XCTAssertFalse(pins.hasSavedApps(deviceID: second.id))
        XCTAssertTrue(devices.loadDevices().devices.isEmpty)
    }

    func testUnknownNestedConnectionUserAndAppFieldsAreRejected() async throws {
        let data = try archive([device("TV", "tv.local")], favorite: 0).encoded()
        for level in ["connection", "user", "app"] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var records = try XCTUnwrap(root["devices"] as? [[String: Any]])
            if level == "connection" {
                var connection = try XCTUnwrap(records[0]["connection"] as? [String: Any])
                connection["unsupported"] = "synthetic"
                records[0]["connection"] = connection
            } else {
                var users = try XCTUnwrap(records[0]["quickLaunch"] as? [[String: Any]])
                if level == "user" { users[0]["unsupported"] = "synthetic" }
                else {
                    var apps = try XCTUnwrap(users[0]["apps"] as? [[String: Any]])
                    apps[0]["unsupported"] = "synthetic"
                    users[0]["apps"] = apps
                }
                records[0]["quickLaunch"] = users
            }
            root["devices"] = records
            XCTAssertThrowsError(try ADBTVConfigurationBackup.decode(JSONSerialization.data(withJSONObject: root)))
        }
    }

    func testConflictingOrCorruptOrphansRejectBeforeStagingAnyDevice() async throws {
        let first = device("First", "one.local")
        let second = device("Second", "two.local")
        let backup = try archive([first, second], favorite: 1)
        for data in [Data("invalid".utf8), try JSONEncoder().encode([
            ADBTVQuickLaunchStore.UserApps(userID: 0, apps: [ADBTVPinnedApp(package: package(9))])
        ])] {
            defaults.set(data, forKey: pinKey(second.id))
            XCTAssertThrowsError(try store.restore(store.preview(backup), selectedIDs: [first.id, second.id]))
            XCTAssertFalse(pins.hasSavedApps(deviceID: first.id))
            XCTAssertEqual(defaults.data(forKey: pinKey(second.id)), data)
            XCTAssertTrue(devices.loadDevices().devices.isEmpty)
        }
    }

    func testCorruptLibraryAndUnrelatedDefaultsAreNeverOverwritten() async throws {
        let backup = try archive([device("New", "new.local")])
        for value: Any in ["wrong preference type", Data("bad JSON".utf8)] {
            defaults.set(value, forKey: devices.key)
            XCTAssertThrowsError(try store.export())
            XCTAssertThrowsError(try store.preview(backup))
            if let data = value as? Data { XCTAssertEqual(defaults.data(forKey: devices.key), data) }
            else { XCTAssertEqual(defaults.string(forKey: devices.key), value as? String) }
        }
    }

    func testCorruptExistingPinsBlockExportWithoutRepairingThem() async throws {
        let tv = device("TV", "tv.local")
        try devices.saveDevices([tv])
        let data = Data("broken pins".utf8)
        defaults.set(data, forKey: pinKey(tv.id))
        XCTAssertThrowsError(try store.export())
        XCTAssertEqual(defaults.data(forKey: pinKey(tv.id)), data)
    }

    func testUnknownVersionAndUnexpectedFieldsAreRejected() async throws {
        let data = try archive([device("TV", "tv.local")], favorite: 0).encoded()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 2
        XCTAssertThrowsError(try ADBTVConfigurationBackup.decode(JSONSerialization.data(withJSONObject: json))) {
            XCTAssertEqual($0 as? ADBTVConfigurationBackupError, .unsupportedVersion)
        }
        json["version"] = 1
        json["unrelatedSetting"] = "not supported"
        XCTAssertThrowsError(try ADBTVConfigurationBackup.decode(JSONSerialization.data(withJSONObject: json)))
        json.removeValue(forKey: "unrelatedSetting")
        var records = try XCTUnwrap(json["devices"] as? [[String: Any]])
        records[0]["credential"] = "synthetic marker"
        json["devices"] = records
        XCTAssertThrowsError(try ADBTVConfigurationBackup.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testInvalidConnectionsNamesAndDuplicateRecordsAreRejected() async throws {
        let valid = try archive([device("TV", "tv.local")])
        var variants = [ADBTVConfigurationBackup]()
        for host in ["", "bad host", "https://tv.local", "user@tv.local", "bad\nhost"] {
            var value = valid; value.devices[0].connection.host = host; variants.append(value)
        }
        for port in [-1, 0, 65536] {
            var value = valid; value.devices[0].connection.port = port; variants.append(value)
        }
        var emptyName = valid; emptyName.devices[0].displayName = " "; variants.append(emptyName)
        var duplicate = valid; duplicate.devices.append(duplicate.devices[0]); variants.append(duplicate)
        var sameEndpoint = valid; var record = valid.devices[0]; record.id = UUID(); sameEndpoint.devices.append(record); variants.append(sameEndpoint)
        var mixed = valid; mixed.devices[0].connection.domain = "local."; variants.append(mixed)
        for value in variants { XCTAssertThrowsError(try value.encoded()) }
        let pairing = ADBTVDeviceSummary(displayName: "Pairing", bonjourService: ADBDiscoveredService(serviceName: "adb-test", serviceType: "_adb-tls-pairing._tcp", domain: "local."))
        XCTAssertThrowsError(try archive([pairing]))
    }

    func testInvalidPinUsersPackagesDuplicatesAndLimitsAreRejected() async throws {
        let original = try archive([device("TV", "tv.local")], favorite: 0)
        var badUsers = original
        badUsers.devices[0].quickLaunch[0].userID = -1
        XCTAssertThrowsError(try badUsers.encoded())
        var duplicateUser = original
        duplicateUser.devices[0].quickLaunch.append(duplicateUser.devices[0].quickLaunch[0])
        XCTAssertThrowsError(try duplicateUser.encoded())
        var duplicateApp = original
        duplicateApp.devices[0].quickLaunch[0].apps.append(duplicateApp.devices[0].quickLaunch[0].apps[0])
        XCTAssertThrowsError(try duplicateApp.encoded())
        var tooMany = original
        tooMany.devices[0].quickLaunch[0].apps = try (0..<7).map { ADBTVPinnedApp(package: try package($0)) }
        XCTAssertThrowsError(try tooMany.encoded())
        let invalid = String(decoding: try original.encoded(), as: UTF8.self)
            .replacingOccurrences(of: "com.example.app0", with: "com.example.app;reboot")
        XCTAssertThrowsError(try ADBTVConfigurationBackup.decode(Data(invalid.utf8)))
    }

    func testByteAndDeviceLimitsAndBoundedFileReader() async throws {
        let data = Data(repeating: 32, count: ADBTVConfigurationBackup.maximumByteCount + 1)
        XCTAssertThrowsError(try ADBTVConfigurationBackup.decode(data)) {
            XCTAssertEqual($0 as? ADBTVConfigurationBackupError, .tooLarge)
        }
        XCTAssertThrowsError(try archive((0...100).map { device("TV \($0)", "tv\($0).local") }).encoded())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ADBTVBackup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let valid = try archive([device("TV", "tv.local")])
        try valid.encoded().write(to: file)
        let decoded = try await ADBTVConfigurationBackup.read(from: file)
        XCTAssertEqual(decoded, valid)
        try data.write(to: file)
        do { _ = try await ADBTVConfigurationBackup.read(from: file); XCTFail("Expected bounded read") }
        catch { XCTAssertEqual(error as? ADBTVConfigurationBackupError, .tooLarge) }
    }

    func testCancelledReaderDoesNotProduceAnImportableResult() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ADBTVBackup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try archive([]).encoded().write(to: file)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ADBTVConfigurationBackup.read(from: file)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func device(_ name: String, _ host: String) -> ADBTVDeviceSummary {
        ADBTVDeviceSummary(displayName: name, host: host, port: 5555, model: "Android TV")
    }

    private func package(_ index: Int) throws -> ADBTVInstalledPackage {
        try ADBTVInstalledPackage(packageName: "com.example.app\(index)")
    }

    private func archive(_ devices: [ADBTVDeviceSummary], favorite: Int? = nil) throws -> ADBTVConfigurationBackup {
        try ADBTVConfigurationBackup(devices: devices.map {
            try .init($0, quickLaunch: favorite.map {
                [.init(userID: 10, apps: [ADBTVPinnedApp(package: try package($0), displayName: "App \($0)")])]
            } ?? [])
        })
    }

    private func pinKey(_ id: UUID) -> String { pins.keyPrefix + id.uuidString }
}

private enum BackupTestError: Error { case failed }
