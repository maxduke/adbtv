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

    func testModelCanInstallOnlyWithDeviceAndValidPackage() {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var model = ADBTVAppModel(devices: [device])

        XCTAssertFalse(model.canInstallSelectedPackage)

        model.selectPackage(fileName: "app.apk", byteCount: 7)

        XCTAssertTrue(model.canInstallSelectedPackage)
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
        XCTAssertEqual(model.installDraft.status, .ready)
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
}
