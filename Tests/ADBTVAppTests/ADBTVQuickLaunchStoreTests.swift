import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVQuickLaunchStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: ADBTVQuickLaunchStore!
    private let deviceID = UUID()

    override func setUp() {
        suite = "ADBTVQuickLaunchStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = ADBTVQuickLaunchStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testPinsPersistWithBoundedNamesAndAreScopedByTVAndAndroidUser() throws {
        let package = try package(0)
        try store.pin(package, displayName: " \(String(repeating: "N", count: 300)) ", deviceID: deviceID, userID: 10)
        let reloaded = ADBTVQuickLaunchStore(userDefaults: defaults)
        let apps = try reloaded.apps(deviceID: deviceID, userID: 10)
        XCTAssertEqual(apps.map(\.packageName), [package.packageName])
        XCTAssertEqual(apps.first?.displayName?.count, 256)
        XCTAssertTrue(try reloaded.apps(deviceID: deviceID, userID: 0).isEmpty)
        XCTAssertTrue(try reloaded.apps(deviceID: UUID(), userID: 10).isEmpty)

        try store.pin(package, displayName: nil, deviceID: deviceID, userID: 0)
        XCTAssertEqual(try store.apps(deviceID: deviceID, userID: 0).first?.title, package.packageName)
        XCTAssertEqual(try store.apps(deviceID: deviceID, userID: 10), apps)
    }

    func testSixAppLimitAppliesPerUserAndStillAllowsUnpinning() throws {
        for index in 0..<6 {
            try store.pin(package(index), displayName: nil, deviceID: deviceID, userID: 10)
        }
        let data = defaults.data(forKey: key)
        XCTAssertThrowsError(try store.pin(package(6), displayName: nil, deviceID: deviceID, userID: 10)) {
            XCTAssertEqual($0 as? ADBTVQuickLaunchError, .limitReached)
        }
        XCTAssertEqual(defaults.data(forKey: key), data)
        try store.pin(package(6), displayName: nil, deviceID: deviceID, userID: 11)
        try store.remove(packageNames: ["com.example.app0"], deviceID: deviceID, userID: 10)
        let apps = try store.pin(package(6), displayName: nil, deviceID: deviceID, userID: 10)
        XCTAssertEqual(apps.count, 6)
        XCTAssertFalse(apps.contains { $0.packageName == "com.example.app0" })
        XCTAssertEqual(try store.apps(deviceID: deviceID, userID: 11).count, 1)
    }

    func testOrderAndRemovalPersistWithoutChangingOtherUsers() throws {
        for index in 0..<3 {
            try store.pin(package(index), displayName: "App \(index)", deviceID: deviceID, userID: 10)
        }
        try store.pin(package(0), displayName: "Owner app", deviceID: deviceID, userID: 0)
        let names = try [2, 0, 1].map { try package($0).packageName }
        try store.reorder(packageNames: names, deviceID: deviceID, userID: 10)
        XCTAssertEqual(try store.apps(deviceID: deviceID, userID: 10).map(\.packageName), names)
        try store.remove(packageNames: [names[1]], deviceID: deviceID, userID: 10)
        XCTAssertEqual(try store.apps(deviceID: deviceID, userID: 10).map(\.packageName), [names[0], names[2]])
        XCTAssertEqual(try store.apps(deviceID: deviceID, userID: 0).first?.title, "Owner app")
    }

    func testRepeatedPinFromStaleWindowCannotUnpinOrEraseKnownName() throws {
        let package = try package(0)
        let otherWindow = ADBTVQuickLaunchStore(userDefaults: defaults)
        try otherWindow.pin(package, displayName: "TV App", deviceID: deviceID, userID: 10)
        try store.pin(package, displayName: nil, deviceID: deviceID, userID: 10)
        let apps = try otherWindow.apps(deviceID: deviceID, userID: 10)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.title, "TV App")
    }

    func testStaleOrInvalidReorderCannotDropAnotherWindowsPins() throws {
        try store.pin(package(0), displayName: nil, deviceID: deviceID, userID: 10)
        let otherWindow = ADBTVQuickLaunchStore(userDefaults: defaults)
        try otherWindow.pin(package(1), displayName: nil, deviceID: deviceID, userID: 10)
        let data = defaults.data(forKey: key)
        for names in [["com.example.app0"], ["com.example.app0", "com.example.app0"], ["com.example.app0", "com.example.unknown"]] {
            XCTAssertThrowsError(try store.reorder(packageNames: names, deviceID: deviceID, userID: 10)) {
                XCTAssertEqual($0 as? ADBTVQuickLaunchError, .changedOrder)
            }
            XCTAssertEqual(defaults.data(forKey: key), data)
        }
    }

    func testDeviceRemovalClearsAllItsUsersAndPreservesOtherData() throws {
        let otherDevice = UUID()
        for user in [0, 10] {
            try store.pin(package(0), displayName: nil, deviceID: deviceID, userID: user)
        }
        try store.pin(package(1), displayName: nil, deviceID: otherDevice, userID: 0)
        defaults.set("Unrelated", forKey: "unrelated.setting")
        store.removeDevice(deviceID)
        XCTAssertFalse(store.hasSavedApps(deviceID: deviceID))
        XCTAssertEqual(try store.apps(deviceID: otherDevice, userID: 0).count, 1)
        XCTAssertEqual(defaults.string(forKey: "unrelated.setting"), "Unrelated")
    }

    func testRenameAndConnectionRepairKeepPinsThroughStableDeviceID() throws {
        let device = ADBTVDeviceSummary(id: deviceID, displayName: "TV", host: "tv.local", port: 5555)
        var model = ADBTVAppModel(devices: [device])
        try store.pin(package(0), displayName: nil, deviceID: deviceID, userID: 0)
        try model.renameDevice(id: deviceID, to: "Living Room")
        let updated = try model.replaceDeviceConnection(
            id: deviceID,
            with: ADBTVDeviceSummary(displayName: "Detected TV", host: "192.168.1.2", port: 4567)
        )
        XCTAssertEqual(updated.id, deviceID)
        XCTAssertEqual(try store.apps(deviceID: updated.id, userID: 0).count, 1)
    }

    func testInvalidArchivesAreNeverOverwrittenByAnEdit() throws {
        let app: [String: Any] = ["packageName": "com.example.app", "displayName": "App"]
        let archives: [Any] = [
            [["userID": -1, "apps": [app]]],
            [["userID": 0, "apps": [app, app]]],
            [["userID": 0, "apps": []], ["userID": 0, "apps": []]],
            [["userID": 0, "apps": [["packageName": "com.example.app;reboot"]]]],
            [["userID": 0, "apps": (0..<7).map { ["packageName": "com.example.app\($0)"] }]],
            ["unexpected": "shape"]
        ]
        for archive in archives {
            let data = try JSONSerialization.data(withJSONObject: archive)
            defaults.set(data, forKey: key)
            XCTAssertThrowsError(try store.apps(deviceID: deviceID, userID: 0))
            XCTAssertThrowsError(try store.pin(package(0), displayName: nil, deviceID: deviceID, userID: 0))
            XCTAssertEqual(defaults.data(forKey: key), data)
        }
    }

    func testWrongPreferenceTypeAndOversizedArchivesArePreserved() throws {
        defaults.set("broken archive", forKey: key)
        XCTAssertThrowsError(try store.pin(package(0), displayName: nil, deviceID: deviceID, userID: 0))
        XCTAssertEqual(defaults.string(forKey: key), "broken archive")
        let data = Data(repeating: 32, count: 256 * 1024 + 1)
        defaults.set(data, forKey: key)
        XCTAssertThrowsError(try store.apps(deviceID: deviceID, userID: 0))
        XCTAssertEqual(defaults.data(forKey: key), data)
    }

    func testInvalidUserDoesNotCreatePreferencesAndLastUnpinRemovesArchive() throws {
        XCTAssertThrowsError(try store.pin(package(0), displayName: nil, deviceID: deviceID, userID: -1))
        XCTAssertFalse(store.hasSavedApps(deviceID: deviceID))
        try store.pin(package(0), displayName: " \n ", deviceID: deviceID, userID: 0)
        XCTAssertEqual(try store.apps(deviceID: deviceID, userID: 0).first?.title, "com.example.app0")
        try store.remove(packageNames: ["com.example.app0"], deviceID: deviceID, userID: 0)
        XCTAssertFalse(store.hasSavedApps(deviceID: deviceID))
    }

    private var key: String { store.keyPrefix + deviceID.uuidString }

    private func package(_ index: Int) throws -> ADBTVInstalledPackage {
        try ADBTVInstalledPackage(packageName: "com.example.app\(index)")
    }
}
