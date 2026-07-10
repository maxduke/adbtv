import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVAppModelTests: XCTestCase {
    func testInitialModelSelectsFirstDevice() {
        let first = ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555)
        let second = ADBTVDeviceSummary(displayName: "Bedroom", host: "192.168.1.51", port: 5555)

        let model = ADBTVAppModel(devices: [first, second])

        XCTAssertEqual(model.selectedDevice, first)
    }

    func testPackageDraftBuildsAPKInstallPlan() throws {
        let draft = ADBTVInstallDraft(
            selectedPackage: ADBTVInstallPackageDraft(fileName: "Example App.apk", byteCount: 42)
        )

        let plan = try draft.installPlan()

        XCTAssertTrue(draft.canBuildInstallPlan)
        XCTAssertEqual(plan.package.fileName, "Example App.apk")
        XCTAssertEqual(plan.package.byteCount, 42)
        XCTAssertEqual(plan.remoteAPKPath.rawValue, "/data/local/tmp/adbtv/Example_App.apk")
    }

    func testPackageDraftRejectsMissingAndNonAPKPackages() {
        XCTAssertThrowsError(try ADBTVInstallDraft().installPlan()) { error in
            XCTAssertEqual(error as? ADBTVInstallDraftError, .missingPackage)
        }

        let draft = ADBTVInstallDraft(
            selectedPackage: ADBTVInstallPackageDraft(fileName: "bundle.apks")
        )

        XCTAssertFalse(draft.canBuildInstallPlan)
    }

    func testInstallURLValidationAllowsHTTPAndHTTPSOnly() {
        XCTAssertEqual(
            ADBTVInstallDraft(urlString: "https://example.com/app.apk").validatedURL?.absoluteString,
            "https://example.com/app.apk"
        )
        XCTAssertEqual(
            ADBTVInstallDraft(urlString: " http://192.168.1.2/app.apk ").validatedURL?.absoluteString,
            "http://192.168.1.2/app.apk"
        )
        XCTAssertNil(ADBTVInstallDraft(urlString: "ftp://example.com/app.apk").validatedURL)
        XCTAssertNil(ADBTVInstallDraft(urlString: "https:///app.apk").validatedURL)
    }

    func testPackageDraftBuildsInstallReadinessFromAPKURL() {
        let draft = ADBTVInstallDraft(urlString: "https://example.com/releases/Example%20App.apk")

        XCTAssertTrue(draft.canBuildInstallPlan)
        XCTAssertEqual(draft.urlFileName, "Example App.apk")
    }

    func testModelCanInstallOnlyWithDeviceAndValidPackage() {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var model = ADBTVAppModel(devices: [device])

        XCTAssertFalse(model.canInstallSelectedPackage)

        model.selectPackage(fileName: "app.apk", byteCount: 7)

        XCTAssertTrue(model.canInstallSelectedPackage)

        model.setInstallURLString("https://example.com/app.apk")

        XCTAssertTrue(model.canInstallSelectedPackage)
        XCTAssertNil(model.installDraft.selectedPackage)
        XCTAssertEqual(model.installDraft.status, .ready)

        model.setInstallURLString("https://example.com/app.apks")

        XCTAssertFalse(model.canInstallSelectedPackage)
        XCTAssertEqual(model.installDraft.status, .idle)
    }

    func testModelAddsAndRemovesDevices() {
        let first = ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555)
        let second = ADBTVDeviceSummary(displayName: "Bedroom", host: "192.168.1.51", port: 5555)
        var model = ADBTVAppModel(devices: [first])

        model.addDevice(second)

        XCTAssertEqual(model.devices, [first, second])
        XCTAssertEqual(model.selectedDevice, second)

        model.removeDevices(ids: [second.id])

        XCTAssertEqual(model.devices, [first])
        XCTAssertEqual(model.selectedDevice, first)
    }

    func testModelUpdatesDeviceAtSameEndpointWithoutCreatingDuplicate() {
        let original = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "tv.local",
            port: 5555
        )
        var model = ADBTVAppModel(devices: [original])

        let savedDevice = model.addDevice(ADBTVDeviceSummary(
            displayName: "Living Room TV",
            host: "TV.LOCAL",
            port: 5555,
            model: "Android TV"
        ))

        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(savedDevice.id, original.id)
        XCTAssertEqual(savedDevice.displayName, "Living Room TV")
        XCTAssertEqual(model.selectedDevice, savedDevice)
    }

    func testDeviceStoreRoundTripsSavedDevices() throws {
        let suiteName = "ADBTVDeviceStoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let store = ADBTVDeviceStore(userDefaults: userDefaults)
        let devices = [
            ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555, model: "Android TV")
        ]

        try store.saveDevices(devices)

        XCTAssertEqual(store.loadDevices(), devices)
    }

    func testModelSelectsPackageFromFileURL() {
        var model = ADBTVAppModel()
        let url = URL(fileURLWithPath: "/tmp/Example App.apk")

        model.selectPackage(fileURL: url, byteCount: 123)

        XCTAssertEqual(model.installDraft.selectedPackage, ADBTVInstallPackageDraft(
            fileName: "Example App.apk",
            fileURL: url,
            byteCount: 123
        ))
        XCTAssertEqual(model.installDraft.urlString, "")
        XCTAssertEqual(model.installDraft.status, .ready)
    }

    func testModelClearsURLWhenSelectingFilePackage() {
        var model = ADBTVAppModel()

        model.setInstallURLString("https://example.com/app.apk")
        model.selectPackage(fileName: "local.apk", byteCount: 12)

        XCTAssertEqual(model.installDraft.urlString, "")
        XCTAssertEqual(model.installDraft.selectedPackage, ADBTVInstallPackageDraft(
            fileName: "local.apk",
            byteCount: 12
        ))
    }

    func testInstallEventsUpdatePresentationStatus() {
        var model = ADBTVAppModel()

        model.recordInstallEvent(.phaseStarted(.transferPackage))
        XCTAssertEqual(model.installDraft.status, .running(.transferPackage))

        model.recordInstallEvent(.transfer(.failed(message: "remote rejected write")))
        XCTAssertEqual(model.installDraft.status, .failed(
            userMessage: "APK transfer failed.",
            diagnosticDetail: DiagnosticDetail(
                summary: "remote rejected write",
                context: ["phase": "transferPackage"]
            )
        ))

        model.finishInstall(result: .failure(message: "INSTALL_FAILED_INVALID_APK"))
        XCTAssertEqual(model.installDraft.status, .failed(
            userMessage: "APK install failed.",
            diagnosticDetail: DiagnosticDetail(
                summary: "INSTALL_FAILED_INVALID_APK",
                context: ["phase": "installPackage"]
            )
        ))
    }

    func testRemoteActionsUpdatePresentationStatus() {
        var model = ADBTVAppModel()

        model.recordRemoteActionStarted(.home)
        XCTAssertEqual(model.remoteStatus, .sending(.home))
        XCTAssertTrue(model.remoteStatus.isSending)

        model.finishRemoteAction(.home)
        XCTAssertEqual(model.remoteStatus, .sent(.home))
        XCTAssertFalse(model.remoteStatus.isSending)

        model.failRemoteAction(
            .settings,
            userMessage: "Could not send remote action.",
            diagnosticDetail: DiagnosticDetail(
                summary: "network unavailable",
                context: ["operation": "sendRemoteAction"]
            )
        )
        XCTAssertEqual(model.remoteStatus, .failed(
            action: .settings,
            userMessage: "Could not send remote action.",
            diagnosticDetail: DiagnosticDetail(
                summary: "network unavailable",
                context: ["operation": "sendRemoteAction"]
            )
        ))
    }

    func testDiscoveryUpdatesPresentationStatusAndServices() {
        var model = ADBTVAppModel()
        let connectService = ADBDiscoveredService(
            serviceName: "Living Room",
            serviceType: ADBWirelessDebuggingServiceKind.connect.bonjourType,
            domain: "local."
        )
        let pairingService = ADBDiscoveredService(
            serviceName: "Living Room Pairing",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )

        model.startDiscovery()

        XCTAssertEqual(model.discoveryStatus, .browsing)
        XCTAssertTrue(model.discoveryStatus.isBrowsing)
        XCTAssertEqual(model.discoveredServices, [])

        model.updateDiscoveredServices([pairingService, connectService])

        XCTAssertEqual(model.discoveryStatus, .browsing)
        XCTAssertEqual(model.discoveredServices, [connectService, pairingService])

        model.stopDiscovery()

        XCTAssertEqual(model.discoveryStatus, .idle)
        XCTAssertFalse(model.discoveryStatus.isBrowsing)
    }

    func testDiscoveryFailureStoresUserAndDiagnosticDetails() {
        var model = ADBTVAppModel()
        let diagnosticDetail = DiagnosticDetail(
            summary: "local network permission denied",
            context: ["operation": "bonjourDiscovery"]
        )

        model.failDiscovery(
            userMessage: "Could not discover Android TV devices.",
            diagnosticDetail: diagnosticDetail
        )

        XCTAssertEqual(model.discoveryStatus, .failed(
            userMessage: "Could not discover Android TV devices.",
            diagnosticDetail: diagnosticDetail
        ))
    }

    func testPairingDraftValidatesManualCodeAndQRCodePayload() {
        var model = ADBTVAppModel()

        XCTAssertFalse(model.pairingDraft.canStartManualPairing)
        XCTAssertFalse(model.pairingDraft.canStartQRPairing)

        model.setPairingDisplayName(" Living Room TV ")
        model.setPairingHost(" 192.168.1.50 ")
        model.setPairingPortString(" 37123 ")
        model.setConnectionPortString("39555")
        model.setPairingCodeString("123 456")

        XCTAssertEqual(model.pairingDraft.pairingCode?.rawValue, "123456")
        XCTAssertEqual(model.pairingDraft.normalizedDisplayName, "Living Room TV")
        XCTAssertEqual(model.pairingDraft.normalizedHost, "192.168.1.50")
        XCTAssertEqual(model.pairingDraft.pairingPort, 37123)
        XCTAssertEqual(model.pairingDraft.connectionPort, 39555)
        XCTAssertTrue(model.pairingDraft.canStartManualPairing)

        model.setPairingQRCodePayload("WIFI:T:ADB;S:Living Room TV;P:pair-secret;;")

        XCTAssertEqual(model.pairingDraft.pairingQRCode, try? ADBPairingQRCode(
            serviceName: "Living Room TV",
            password: "pair-secret"
        ))
        XCTAssertTrue(model.pairingDraft.canStartQRPairing)

        model.setPairingCodeString("12345")
        model.setPairingPortString("0")
        model.setPairingQRCodePayload("WIFI:T:WPA;S:Network;P:secret;;")

        XCTAssertFalse(model.pairingDraft.canStartManualPairing)
        XCTAssertFalse(model.pairingDraft.canStartQRPairing)
    }

    func testPairingDraftUsesHostAsDefaultDisplayName() {
        let draft = ADBTVPairingDraft(
            host: " tv.local ",
            pairingPortString: "37123",
            connectionPortString: "39555",
            codeString: "123456"
        )

        XCTAssertEqual(draft.normalizedDisplayName, "tv.local")
        XCTAssertTrue(draft.canStartManualPairing)
    }

    func testPairingStatusTracksStartSuccessAndSelectedDevice() {
        var model = ADBTVAppModel()
        let device = ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555)

        model.startPairing(source: .manualCode, target: "192.168.1.50:37123")

        XCTAssertEqual(model.pairingStatus, .pairing(source: .manualCode, target: "192.168.1.50:37123"))
        XCTAssertTrue(model.pairingStatus.isPairing)

        model.finishPairing(device: device)

        XCTAssertEqual(model.pairingStatus, .paired(device))
        XCTAssertEqual(model.devices, [device])
        XCTAssertEqual(model.selectedDevice, device)
        XCTAssertEqual(model.pairingDraft.codeString, "")
    }

    func testPairingFailureStoresUserAndDiagnosticDetails() {
        var model = ADBTVAppModel()
        let diagnosticDetail = DiagnosticDetail(
            summary: "SPAKE2 authentication failed",
            context: ["operation": "pairDevice"]
        )

        model.failPairing(
            userMessage: "Could not pair with this Android TV.",
            diagnosticDetail: diagnosticDetail
        )

        XCTAssertEqual(model.pairingStatus, .failed(
            userMessage: "Could not pair with this Android TV.",
            diagnosticDetail: diagnosticDetail
        ))
        XCTAssertFalse(model.pairingStatus.isPairing)
    }
}
