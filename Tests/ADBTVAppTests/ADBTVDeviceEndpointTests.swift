import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVDeviceEndpointTests: XCTestCase {
    func testBonjourIdentityNormalizesCaseAndDomainDotsAndIgnoresLocalInterface() {
        XCTAssertEqual(
            ADBTVDeviceEndpoint(bonjour("adb-tv-example", domain: "local.", interface: "en0")),
            ADBTVDeviceEndpoint(bonjour("ADB-TV-EXAMPLE", domain: "LOCAL", interface: "en9"))
        )
    }

    func testIdentityKeepsConnectionKindsPortsNamesDomainsAndServiceKindsSeparate() {
        let reference = ADBTVDeviceEndpoint(bonjour("adb-tv-example"))
        for different in [
            bonjour("adb-other"),
            bonjour("adb-tv-example", domain: "example."),
            bonjour("adb-tv-example", type: "_adb-tls-pairing._tcp"),
            .hostPort(host: "adb-tv-example", port: 5555)
        ] {
            XCTAssertNotEqual(reference, ADBTVDeviceEndpoint(different))
        }
        XCTAssertEqual(
            ADBTVDeviceEndpoint(.hostPort(host: "TV.Local", port: 5555)),
            ADBTVDeviceEndpoint(.hostPort(host: "tv.local", port: 5555))
        )
        XCTAssertNotEqual(
            ADBTVDeviceEndpoint(.hostPort(host: "tv.local", port: 5555)),
            ADBTVDeviceEndpoint(.hostPort(host: "tv.local", port: 4555))
        )
    }

    func testAddingEquivalentBonjourDeviceKeepsIdentityAndNameAndCanBeExported() throws {
        let original = ADBTVDeviceSummary(displayName: "Living Room", bonjourService: .init(
            serviceName: "adb-tv-example", serviceType: "_adb-tls-connect._tcp", domain: "local.", interfaceName: "en0"
        ))
        let refreshed = ADBTVDeviceSummary(displayName: "Ignored", bonjourService: .init(
            serviceName: "ADB-TV-EXAMPLE", serviceType: "_adb-tls-connect._tcp", domain: "LOCAL", interfaceName: "en9"
        ))
        let suite = "ADBTVDeviceEndpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = ADBTVQuickLaunchStore(userDefaults: defaults)
        try pins.pin(ADBTVInstalledPackage(packageName: "com.example.app"), displayName: "Movie", deviceID: original.id, userID: 10)
        let savedPins = try XCTUnwrap(defaults.data(forKey: "ADBTV.quickLaunch.\(original.id.uuidString)"))
        var model = ADBTVAppModel(devices: [original])
        let saved = model.addDevice(refreshed)
        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.displayName, original.displayName)
        XCTAssertEqual(saved.connection, refreshed.connection)
        let store = ADBTVDeviceStore(userDefaults: defaults)
        try store.saveDevices(model.devices)
        let backup = try ADBTVConfigurationBackup.decode(ADBTVConfigurationBackupStore(deviceStore: store).export())
        XCTAssertEqual(backup.devices.map(\.id), [original.id])
        XCTAssertEqual(backup.devices[0].quickLaunch.first?.userID, 10)
        XCTAssertEqual(backup.devices[0].quickLaunch.first?.apps.first?.packageName, "com.example.app")
        XCTAssertEqual(defaults.data(forKey: "ADBTV.quickLaunch.\(original.id.uuidString)"), savedPins)
    }

    func testRepairRejectsEquivalentBonjourEndpointWithoutChangingEitherDevice() throws {
        let saved = ADBTVDeviceSummary(displayName: "Living Room", bonjourService: .init(
            serviceName: "adb-tv-example", serviceType: "_adb-tls-connect._tcp", domain: "local."
        ))
        let other = ADBTVDeviceSummary(displayName: "Bedroom", host: "bedroom.local", port: 5555)
        let verified = ADBTVDeviceSummary(displayName: "Ignored", bonjourService: .init(
            serviceName: "ADB-TV-EXAMPLE", serviceType: "_adb-tls-connect._tcp", domain: "LOCAL"
        ))
        var model = ADBTVAppModel(devices: [saved, other])
        XCTAssertThrowsError(try model.replaceDeviceConnection(id: other.id, with: verified)) {
            XCTAssertEqual($0 as? ADBTVDeviceRepairError, .endpointAlreadySaved(displayName: saved.displayName))
        }
        XCTAssertEqual(model.devices, [saved, other])
    }

    func testExistingAmbiguousArchivesAreRejectedWithoutAutomaticMergingOrRewriting() throws {
        let suite = "ADBTVDeviceEndpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ADBTVDeviceStore(userDefaults: defaults)
        let records = ["adb-tv-example", "ADB-TV-EXAMPLE"].map {
            ADBTVDeviceSummary(displayName: $0, bonjourService: .init(
                serviceName: $0, serviceType: "_adb-tls-connect._tcp", domain: "local."
            ))
        }
        try store.saveDevices(records)
        let bytes = defaults.data(forKey: store.key)
        XCTAssertThrowsError(try ADBTVConfigurationBackupStore(deviceStore: store).export())
        XCTAssertEqual(defaults.data(forKey: store.key), bytes)
        XCTAssertEqual(store.loadDevices().devices, records)
    }

    private func bonjour(_ name: String, domain: String = "local.",
                         interface: String? = nil, type: String = "_adb-tls-connect._tcp") -> ADBTVDeviceConnection {
        .bonjour(.init(serviceName: name, serviceType: type, domain: domain, interfaceName: interface))
    }
}
