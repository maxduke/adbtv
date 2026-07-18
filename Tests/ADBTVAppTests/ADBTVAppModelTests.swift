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
        XCTAssertTrue(plan.remoteAPKPath.rawValue.hasPrefix("/data/local/tmp/adbtv/"))
        XCTAssertTrue(plan.remoteAPKPath.rawValue.hasSuffix(".apk"))
        XCTAssertNotEqual(plan.remoteAPKPath.rawValue, "/data/local/tmp/adbtv/Example_App.apk")
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
        XCTAssertTrue(ADBTVInstallDraft(urlString: "http://192.168.1.2/app.apk").usesInsecureHTTP)
        XCTAssertFalse(ADBTVInstallDraft(urlString: "https://example.com/app.apk").usesInsecureHTTP)
        XCTAssertFalse(ADBTVInstallDraft(urlString: "not a URL").usesInsecureHTTP)
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
        XCTAssertNil(model.selectedDevice)
    }

    func testModelUpdatesDeviceAtSameEndpointWithoutCreatingDuplicateOrLosingName() throws {
        let original = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "tv.local",
            port: 5555
        )
        var model = ADBTVAppModel(devices: [original])
        try model.renameDevice(id: original.id, to: "Family Room")

        let savedDevice = model.addDevice(ADBTVDeviceSummary(
            displayName: "Living Room TV",
            host: "TV.LOCAL",
            port: 5555,
            model: "Android TV"
        ))

        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(savedDevice.id, original.id)
        XCTAssertEqual(savedDevice.displayName, "Family Room")
        XCTAssertEqual(savedDevice.model, "Android TV")
        XCTAssertEqual(model.selectedDevice, savedDevice)
    }

    func testModelRenamesDeviceWithoutChangingIdentityOrConnection() throws {
        let device = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 5555
        )
        var model = ADBTVAppModel(devices: [device])

        let renamed = try model.renameDevice(id: device.id, to: "  Family Room  ")

        XCTAssertEqual(renamed.displayName, "Family Room")
        XCTAssertEqual(renamed.id, device.id)
        XCTAssertEqual(renamed.connection, device.connection)
        XCTAssertEqual(model.selectedDevice, renamed)
    }

    func testModelRejectsEmptyRenameWithoutChangingDevice() {
        let device = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 5555
        )
        var model = ADBTVAppModel(devices: [device])

        XCTAssertThrowsError(try model.renameDevice(id: device.id, to: " \n ")) { error in
            XCTAssertEqual(error as? ADBTVDeviceRenameError, .emptyDisplayName)
        }
        XCTAssertEqual(model.devices, [device])
    }

    func testModelReplacesVerifiedDeviceConnectionWithoutChangingIdentityOrName() throws {
        let original = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 5555,
            model: "Chromecast"
        )
        var model = ADBTVAppModel(devices: [original])
        let verified = ADBTVDeviceSummary(
            displayName: "Ignored Name",
            host: "192.168.1.50",
            port: 39555,
            model: "Google TV Streamer"
        )

        let repaired = try model.replaceDeviceConnection(id: original.id, with: verified)

        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(repaired.id, original.id)
        XCTAssertEqual(repaired.displayName, original.displayName)
        XCTAssertEqual(repaired.connection, verified.connection)
        XCTAssertEqual(repaired.model, "Google TV Streamer")
        XCTAssertEqual(model.selectedDevice, repaired)
    }

    func testModelRejectsRepairToAnotherSavedEndpointWithoutChangingDevices() throws {
        let livingRoom = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 5555
        )
        let bedroom = ADBTVDeviceSummary(
            displayName: "Bedroom",
            host: "192.168.1.51",
            port: 5555
        )
        var model = ADBTVAppModel(devices: [livingRoom, bedroom])
        let originalDevices = model.devices
        let duplicateEndpoint = ADBTVDeviceSummary(
            displayName: livingRoom.displayName,
            host: bedroom.host,
            port: bedroom.port
        )

        XCTAssertThrowsError(
            try model.replaceDeviceConnection(id: livingRoom.id, with: duplicateEndpoint)
        ) { error in
            XCTAssertEqual(
                error as? ADBTVDeviceRepairError,
                .endpointAlreadySaved(displayName: bedroom.displayName)
            )
        }
        XCTAssertEqual(model.devices, originalDevices)
    }

    func testModelRejectsRepairDuringActiveDeviceOperation() {
        let device = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 5555
        )
        var model = ADBTVAppModel(
            devices: [device],
            activeDeviceOperation: .remoteAction(deviceID: device.id, action: .home)
        )

        XCTAssertThrowsError(
            try model.replaceDeviceConnection(id: device.id, with: device)
        ) { error in
            XCTAssertEqual(error as? ADBTVDeviceRepairError, .operationInProgress)
        }
    }

#if canImport(Network)
    func testDeviceConnectionBuildsHostPortAndBonjourNetworkTargets() throws {
        let hostDevice = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 39555
        )
        let connectService = ADBDiscoveredService(
            serviceName: "adb-device-guid",
            serviceType: ADBWirelessDebuggingServiceKind.connect.bonjourType,
            domain: "local."
        )
        let bonjourDevice = ADBTVDeviceSummary(
            displayName: "Bedroom",
            bonjourService: connectService
        )

        XCTAssertEqual(
            try hostDevice.networkTarget(),
            .hostPort(ADBNetworkEndpoint(host: "192.168.1.50", port: 39555))
        )
        XCTAssertEqual(try bonjourDevice.networkTarget(), .bonjourService(connectService))
    }

    func testDeviceConnectionRejectsInvalidPortAndPairingService() throws {
        let invalidPortDevice = ADBTVDeviceSummary(
            displayName: "TV",
            host: "192.168.1.50",
            port: 70_000
        )
        let pairingService = ADBDiscoveredService(
            serviceName: "pairing-session",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        let invalidServiceDevice = ADBTVDeviceSummary(
            displayName: "TV",
            bonjourService: pairingService
        )

        XCTAssertThrowsError(try invalidPortDevice.networkTarget()) { error in
            XCTAssertEqual(error as? ADBTVDeviceConnectionError, .invalidPort(70_000))
        }
        XCTAssertThrowsError(try invalidServiceDevice.networkTarget()) { error in
            XCTAssertEqual(
                error as? ADBTVDeviceConnectionError,
                .invalidBonjourServiceType(pairingService.serviceType)
            )
        }
    }
#endif

    func testDeviceStoreRoundTripsSavedDevices() throws {
        let suiteName = "ADBTVDeviceStoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let store = ADBTVDeviceStore(userDefaults: userDefaults)
        let devices = [
            ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555, model: "Android TV"),
            ADBTVDeviceSummary(
                displayName: "Bedroom",
                bonjourService: ADBDiscoveredService(
                    serviceName: "adb-bedroom-guid",
                    serviceType: ADBWirelessDebuggingServiceKind.connect.bonjourType,
                    domain: "local."
                ),
                model: "Android TV"
            )
        ]

        try store.saveDevices(devices)

        XCTAssertEqual(store.loadDevices(), ADBTVDeviceStoreLoadResult(devices: devices))
    }

    func testDeviceStoreLoadsLegacyHostPortDeviceWithoutBonjourField() throws {
        let suiteName = "ADBTVDeviceStoreLegacyTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let data = try XCTUnwrap("""
        [{"id":"11111111-1111-1111-1111-111111111111","displayName":"Legacy TV","host":"192.168.1.50","port":5555}]
        """.data(using: .utf8))
        userDefaults.set(data, forKey: "ADBTV.savedDevices")

        let result = ADBTVDeviceStore(userDefaults: userDefaults).loadDevices()

        XCTAssertEqual(result.devices.count, 1)
        XCTAssertEqual(result.devices.first?.displayName, "Legacy TV")
        XCTAssertNil(result.devices.first?.bonjourService)
        XCTAssertFalse(result.hasFailures)
    }

    func testDeviceStoreRecoversValidRecordsFromPartiallyInvalidArchive() throws {
        let suiteName = "ADBTVDeviceStorePartialRecoveryTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let device = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 5555
        )
        let validRecordData = try JSONEncoder().encode(device)
        let validRecord = try JSONSerialization.jsonObject(with: validRecordData)
        let archive = try JSONSerialization.data(withJSONObject: [
            validRecord,
            ["id": "not-a-uuid", "displayName": "Broken TV"]
        ])
        userDefaults.set(archive, forKey: "ADBTV.savedDevices")

        let result = ADBTVDeviceStore(userDefaults: userDefaults).loadDevices()

        XCTAssertEqual(result.devices, [device])
        XCTAssertEqual(result.rejectedRecordCount, 1)
        XCTAssertNotNil(result.failureDescription)
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(userDefaults.data(forKey: "ADBTV.savedDevices"), archive)
    }

    func testDeviceStoreReportsUnreadableArchiveWithoutDeletingIt() throws {
        let suiteName = "ADBTVDeviceStoreInvalidArchiveTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let archive = Data("not-json".utf8)
        userDefaults.set(archive, forKey: "ADBTV.savedDevices")

        let result = ADBTVDeviceStore(userDefaults: userDefaults).loadDevices()

        XCTAssertEqual(result.devices, [])
        XCTAssertEqual(result.rejectedRecordCount, 0)
        XCTAssertNotNil(result.failureDescription)
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(userDefaults.data(forKey: "ADBTV.savedDevices"), archive)
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

    func testInstallEventsUpdatePresentationStatus() throws {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var model = ADBTVAppModel(devices: [device])
        model.setInstallURLString("https://example.com/app.apk")
        model.startInstall(on: device.id)

        model.recordInstallEvent(.download(ADBTVInstallDownloadProgress(
            receivedByteCount: 25,
            totalByteCount: 100
        )), on: device.id)
        XCTAssertEqual(
            model.installDraft.status,
            .downloading(receivedByteCount: 25, totalByteCount: 100)
        )
        XCTAssertTrue(model.installDraft.status.isRunning)

        model.recordInstallEvent(.installer(.phaseStarted(.transferPackage)), on: device.id)
        XCTAssertEqual(model.installDraft.status, .running(.transferPackage))

        model.recordInstallEvent(.installer(.transfer(.started(
            remotePath: try ADBRemotePath("/data/local/tmp/adbtv/app.apk"),
            totalByteCount: 100
        ))), on: device.id)
        XCTAssertEqual(
            model.installDraft.status,
            .transferring(sentByteCount: 0, totalByteCount: 100)
        )
        XCTAssertTrue(model.installDraft.status.isRunning)

        model.recordInstallEvent(.installer(.transfer(.progress(
            sentByteCount: 64,
            totalByteCount: 100
        ))), on: device.id)
        XCTAssertEqual(
            model.installDraft.status,
            .transferring(sentByteCount: 64, totalByteCount: 100)
        )

        model.recordInstallEvent(
            .installer(.transfer(.failed(message: "remote rejected write"))),
            on: device.id
        )
        XCTAssertEqual(model.installDraft.status, .failed(
            userMessage: "APK transfer failed.",
            diagnosticDetail: DiagnosticDetail(
                summary: "remote rejected write",
                context: ["phase": "transferPackage"]
            )
        ))
        model.recordInstallEvent(.installer(.phaseStarted(.cleanup)), on: device.id)
        XCTAssertEqual(model.installDraft.status, .failed(
            userMessage: "APK transfer failed.",
            diagnosticDetail: DiagnosticDetail(
                summary: "remote rejected write",
                context: ["phase": "transferPackage"]
            )
        ))

        model.finishInstall(
            result: .failure(message: "INSTALL_FAILED_INVALID_APK"),
            on: device.id
        )
        XCTAssertEqual(model.installDraft.status, .failed(
            userMessage: "APK install failed.",
            diagnosticDetail: DiagnosticDetail(
                summary: "INSTALL_FAILED_INVALID_APK",
                context: ["phase": "installPackage"]
            )
        ))
    }

    func testCancelInstallStopsRunningStatusAndAllowsRetry() {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var model = ADBTVAppModel(devices: [device])

        model.cancelInstall(on: device.id)
        XCTAssertEqual(model.installDraft.status, .idle)

        model.selectPackage(fileName: "app.apk", byteCount: 100)
        model.startInstall(on: device.id)
        XCTAssertTrue(model.installDraft.status.isRunning)

        model.cancelInstall(on: device.id)

        XCTAssertEqual(model.installDraft.status, .cancelled)
        XCTAssertFalse(model.installDraft.status.isRunning)
        XCTAssertTrue(model.installDraft.canBuildInstallPlan)

        model.recordInstallEvent(.installer(.phaseStarted(.installPackage)), on: device.id)
        XCTAssertEqual(model.installDraft.status, .cancelled)
    }

    func testCancellingInstallKeepsOwnershipUntilCleanupFinishes() {
        let first = ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555)
        let second = ADBTVDeviceSummary(displayName: "Bedroom", host: "192.168.1.51", port: 5555)
        var model = ADBTVAppModel(devices: [first, second])
        model.selectPackage(fileName: "app.apk", byteCount: 100)
        XCTAssertTrue(model.startInstall(on: first.id))

        XCTAssertTrue(model.beginCancellingInstall(on: first.id))
        XCTAssertEqual(model.installDraft.status, .cancelling)
        XCTAssertTrue(model.installDraft.status.isRunning)
        XCTAssertFalse(model.installDraft.status.canCancel)
        XCTAssertEqual(model.activeDeviceOperation, .install(deviceID: first.id))
        XCTAssertFalse(model.selectDevice(id: second.id))
        XCTAssertFalse(model.recordInstallEvent(
            .installer(.transfer(.progress(sentByteCount: 100, totalByteCount: 100))),
            on: first.id
        ))
        XCTAssertEqual(model.installDraft.status, .cancelling)

        let cleanupFailure = DiagnosticDetail(
            summary: "cleanup timed out",
            context: ["phase": "cleanup"]
        )
        XCTAssertTrue(model.finishCancellingInstall(
            cleanupFailure: cleanupFailure,
            on: first.id
        ))
        XCTAssertEqual(
            model.installDraft.status,
            .cancelledWithCleanupFailure(cleanupFailure)
        )
        XCTAssertNil(model.activeDeviceOperation)
        XCTAssertTrue(model.selectDevice(id: second.id))
    }

    func testInstallOwnsItsTargetUntilMatchingCompletion() {
        let first = ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555)
        let second = ADBTVDeviceSummary(displayName: "Bedroom", host: "192.168.1.51", port: 5555)
        var model = ADBTVAppModel(devices: [first, second])
        model.selectPackage(fileName: "app.apk", byteCount: 100)

        XCTAssertTrue(model.startInstall(on: first.id))
        XCTAssertEqual(model.activeDeviceOperation, .install(deviceID: first.id))
        XCTAssertFalse(model.canInstallSelectedPackage)
        XCTAssertFalse(model.canStartDeviceOperation)
        XCTAssertFalse(model.selectDevice(id: second.id))
        XCTAssertEqual(model.selectedDevice, first)

        model.removeDevices(ids: [first.id])
        XCTAssertEqual(model.devices, [first, second])
        XCTAssertFalse(model.recordRemoteActionStarted(.home, on: first.id))
        XCTAssertFalse(model.recordInstallEvent(
            .installer(.phaseStarted(.transferPackage)),
            on: second.id
        ))
        XCTAssertFalse(model.finishInstall(result: .success, on: second.id))
        XCTAssertEqual(model.activeDeviceOperation, .install(deviceID: first.id))

        XCTAssertTrue(model.finishInstall(result: .success, on: first.id))
        XCTAssertNil(model.activeDeviceOperation)
        XCTAssertEqual(model.installDraft.status, .succeeded)
        XCTAssertTrue(model.selectDevice(id: second.id))
        XCTAssertEqual(model.selectedDevice, second)
    }

    func testInstalledAppOperationOwnsItsTargetUntilMatchingCompletion() {
        let first = ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555)
        let second = ADBTVDeviceSummary(displayName: "Bedroom", host: "192.168.1.51", port: 5555)
        var model = ADBTVAppModel(devices: [first, second])

        XCTAssertTrue(model.startInstalledAppOperation(on: first.id))
        XCTAssertEqual(model.activeDeviceOperation, .installedApps(deviceID: first.id))
        XCTAssertFalse(model.selectDevice(id: second.id))
        XCTAssertFalse(model.recordRemoteActionStarted(.home, on: first.id))
        XCTAssertFalse(model.finishInstalledAppOperation(on: second.id))
        XCTAssertFalse(model.cancelInstalledAppOperation(on: second.id))

        XCTAssertTrue(model.cancelInstalledAppOperation(on: first.id))
        XCTAssertNil(model.activeDeviceOperation)
        XCTAssertFalse(model.finishInstalledAppOperation(on: first.id))
        XCTAssertTrue(model.selectDevice(id: second.id))
    }

    func testDeviceToolsOperationOwnsItsTargetUntilMatchingCompletion() {
        let first = ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555)
        let second = ADBTVDeviceSummary(displayName: "Bedroom", host: "192.168.1.51", port: 5555)
        var model = ADBTVAppModel(devices: [first, second])

        XCTAssertTrue(model.startDeviceToolsOperation(on: first.id))
        XCTAssertEqual(model.activeDeviceOperation, .deviceTools(deviceID: first.id))
        XCTAssertFalse(model.selectDevice(id: second.id))
        XCTAssertFalse(model.startInstalledAppOperation(on: first.id))
        XCTAssertFalse(model.finishDeviceToolsOperation(on: second.id))
        XCTAssertFalse(model.cancelDeviceToolsOperation(on: second.id))

        XCTAssertTrue(model.cancelDeviceToolsOperation(on: first.id))
        XCTAssertNil(model.activeDeviceOperation)
        XCTAssertFalse(model.finishDeviceToolsOperation(on: first.id))
        XCTAssertTrue(model.selectDevice(id: second.id))
    }

    func testRemoteOperationRejectsOverlapAndStaleCompletion() {
        let first = ADBTVDeviceSummary(displayName: "Living Room", host: "192.168.1.50", port: 5555)
        let second = ADBTVDeviceSummary(displayName: "Bedroom", host: "192.168.1.51", port: 5555)
        var model = ADBTVAppModel(devices: [first, second])
        model.selectPackage(fileName: "app.apk", byteCount: 100)

        XCTAssertTrue(model.recordRemoteActionStarted(.home, on: first.id))
        XCTAssertFalse(model.startInstall(on: first.id))
        XCTAssertFalse(model.finishRemoteAction(.settings, on: first.id))
        XCTAssertFalse(model.finishRemoteAction(.home, on: second.id))
        XCTAssertEqual(
            model.activeDeviceOperation,
            .remoteAction(deviceID: first.id, action: .home)
        )

        XCTAssertTrue(model.finishRemoteAction(.home, on: first.id))
        XCTAssertNil(model.activeDeviceOperation)
        XCTAssertEqual(model.remoteStatus, .sent(.home))

        model.setRemoteTextString("hello")
        XCTAssertTrue(model.recordRemoteTextStarted(on: first.id))
        model.cancelActiveDeviceOperation()
        XCTAssertNil(model.activeDeviceOperation)
        XCTAssertEqual(model.remoteStatus, .idle)
        XCTAssertEqual(model.remoteTextString, "hello")
    }

    func testStartURLInstallImmediatelyEntersDownloadingStatus() {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var model = ADBTVAppModel(devices: [device])
        model.setInstallURLString("https://example.com/app.apk")

        model.startInstall(on: device.id)

        XCTAssertEqual(
            model.installDraft.status,
            .downloading(receivedByteCount: 0, totalByteCount: nil)
        )
        XCTAssertTrue(model.installDraft.status.isRunning)
    }

    func testRemoteActionsUpdatePresentationStatus() {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var model = ADBTVAppModel(devices: [device])

        model.recordRemoteActionStarted(.home, on: device.id)
        XCTAssertEqual(model.remoteStatus, .sending(.home))
        XCTAssertTrue(model.remoteStatus.isSending)

        model.finishRemoteAction(.home, on: device.id)
        XCTAssertEqual(model.remoteStatus, .sent(.home))
        XCTAssertFalse(model.remoteStatus.isSending)

        model.recordRemoteActionStarted(.settings, on: device.id)
        model.failRemoteAction(
            .settings,
            userMessage: "Could not send remote action.",
            diagnosticDetail: DiagnosticDetail(
                summary: "network unavailable",
                context: ["operation": "sendRemoteAction"]
            ),
            on: device.id
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

    func testRemoteTextValidationAndPresentationStatus() throws {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var model = ADBTVAppModel(devices: [device])

        XCTAssertFalse(model.canSendRemoteText)
        model.setRemoteTextString("hello tv")
        XCTAssertEqual(model.remoteText, try ADBTVRemoteText("hello tv"))
        XCTAssertTrue(model.canSendRemoteText)

        model.recordRemoteTextStarted(on: device.id)
        XCTAssertEqual(model.remoteStatus, .sendingText)
        XCTAssertTrue(model.remoteStatus.isSending)
        XCTAssertFalse(model.canSendRemoteText)

        model.finishRemoteText(on: device.id)
        XCTAssertEqual(model.remoteStatus, .sentText)
        XCTAssertEqual(model.remoteTextString, "")

        let diagnostic = DiagnosticDetail(
            summary: "device rejected input",
            context: ["operation": "sendRemoteText"]
        )
        model.setRemoteTextString("retry")
        model.recordRemoteTextStarted(on: device.id)
        model.failRemoteText(
            userMessage: "Could not send text.",
            diagnosticDetail: diagnostic,
            on: device.id
        )
        XCTAssertEqual(model.remoteStatus, .failedText(
            userMessage: "Could not send text.",
            diagnosticDetail: diagnostic
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

    func testDiscoveryWaitsForAuthorizationWithoutStoppingBrowserState() {
        var model = ADBTVAppModel()
        let detail = DiagnosticDetail(
            summary: "PolicyDenied",
            context: ["reason": "localNetworkDenied"]
        )

        model.startDiscovery()
        model.waitForLocalNetworkAuthorization(
            userMessage: "Allow Local Network access.",
            diagnosticDetail: detail
        )

        XCTAssertEqual(
            model.discoveryStatus,
            .waitingForLocalNetworkAuthorization(
                userMessage: "Allow Local Network access.",
                diagnosticDetail: detail
            )
        )
        XCTAssertTrue(model.discoveryStatus.isBrowsing)

        model.markDiscoveryReady()

        XCTAssertEqual(model.discoveryStatus, .browsing)
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

    func testPairingDraftValidatesDiscoveredPairingService() {
        let pairingService = ADBDiscoveredService(
            serviceName: "adb-pairing-guid",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        var model = ADBTVAppModel()

        model.prepareDiscoveredPairing(service: pairingService)
        model.setPairingCodeString("123456")

        XCTAssertEqual(model.pairingDraft.discoveredService, pairingService)
        XCTAssertEqual(model.pairingDraft.normalizedDisplayName, "adb-pairing-guid")
        XCTAssertTrue(model.pairingDraft.canStartDiscoveredPairing)
        XCTAssertTrue(model.pairingDraft.canStartPairing)
        XCTAssertFalse(model.pairingDraft.canStartManualPairing)

        model.prepareManualPairing()

        XCTAssertNil(model.pairingDraft.discoveredService)
        XCTAssertEqual(model.pairingStatus, .idle)
    }

    func testDiscoveredPairingWaitsForMatchingConnectServiceThenRequiresVerification() {
        let pairingService = ADBDiscoveredService(
            serviceName: "pairing-session",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        let unrelatedConnectService = ADBDiscoveredService(
            serviceName: "adb-other-guid",
            serviceType: ADBWirelessDebuggingServiceKind.connect.bonjourType,
            domain: "local."
        )
        let matchingConnectService = ADBDiscoveredService(
            serviceName: "adb-device-guid",
            serviceType: ADBWirelessDebuggingServiceKind.connect.bonjourType,
            domain: "local.",
            interfaceName: "en0"
        )
        var model = ADBTVAppModel(discoveredServices: [pairingService, unrelatedConnectService])

        XCTAssertNil(model.waitForDiscoveredConnection(
            deviceGUID: "adb-device-guid",
            displayName: "Living Room TV"
        ))
        XCTAssertEqual(model.pairingStatus, .waitingForConnection(
            deviceGUID: "adb-device-guid",
            displayName: "Living Room TV"
        ))
        XCTAssertTrue(model.pairingStatus.isPairing)
        XCTAssertTrue(model.devices.isEmpty)

        let candidate = model.updateDiscoveredServices([
            pairingService,
            unrelatedConnectService,
            matchingConnectService
        ])

        guard let candidate else {
            return XCTFail("Expected a discovered connection candidate.")
        }
        XCTAssertEqual(candidate.displayName, "Living Room TV")
        XCTAssertEqual(candidate.bonjourService, matchingConnectService)
        XCTAssertEqual(candidate.connectionDescription, "adb-device-guid via Bonjour")
        XCTAssertEqual(model.pairingStatus, .verifyingConnection(candidate))
        XCTAssertTrue(model.pairingStatus.isPairing)
        XCTAssertTrue(model.devices.isEmpty)
    }

    func testConnectionServiceFailureOnlyAppliesToMatchingPendingPairing() {
        let diagnostic = DiagnosticDetail(
            summary: "timed out",
            context: ["operation": "findConnectionService"]
        )
        var model = ADBTVAppModel()
        XCTAssertNil(model.waitForDiscoveredConnection(
            deviceGUID: "expected-guid",
            displayName: "Living Room TV"
        ))

        XCTAssertFalse(model.failWaitingForConnection(
            deviceGUID: "stale-guid",
            userMessage: "Connection service not found.",
            diagnosticDetail: diagnostic
        ))
        XCTAssertEqual(model.pairingStatus, .waitingForConnection(
            deviceGUID: "expected-guid",
            displayName: "Living Room TV"
        ))

        XCTAssertTrue(model.failWaitingForConnection(
            deviceGUID: "expected-guid",
            userMessage: "Connection service not found.",
            diagnosticDetail: diagnostic
        ))
        XCTAssertEqual(model.pairingStatus, .failed(
            userMessage: "Connection service not found.",
            diagnosticDetail: diagnostic
        ))
    }

    func testPairingServiceFailureOnlyAppliesToMatchingPendingQRCode() {
        let diagnostic = DiagnosticDetail(
            summary: "timed out",
            context: ["operation": "findPairingService"]
        )
        var model = ADBTVAppModel()
        model.prepareQRCodePairing(
            payload: "WIFI:T:ADB;S:expected-service;P:pair-secret;;"
        )

        XCTAssertFalse(model.failWaitingForPairingService(
            serviceName: "stale-service",
            userMessage: "Pairing service not found.",
            diagnosticDetail: diagnostic
        ))
        XCTAssertEqual(
            model.pairingStatus,
            .waitingForPairingService(serviceName: "expected-service")
        )

        XCTAssertTrue(model.failWaitingForPairingService(
            serviceName: "expected-service",
            userMessage: "Pairing service not found.",
            diagnosticDetail: diagnostic
        ))
        XCTAssertEqual(model.pairingStatus, .failed(
            userMessage: "Pairing service not found.",
            diagnosticDetail: diagnostic
        ))
    }

    func testQRCodePairingWaitsForMatchingPairingService() {
        let unrelatedService = ADBDiscoveredService(
            serviceName: "other-service",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        let matchingService = ADBDiscoveredService(
            serviceName: "adb-qr-service",
            serviceType: ADBWirelessDebuggingServiceKind.pairing.bonjourType,
            domain: "local."
        )
        var model = ADBTVAppModel(discoveredServices: [unrelatedService])

        model.prepareQRCodePairing(
            payload: "WIFI:T:ADB;S:adb-qr-service;P:qr-secret;;"
        )

        XCTAssertEqual(
            model.pairingStatus,
            .waitingForPairingService(serviceName: "adb-qr-service")
        )
        XCTAssertTrue(model.pairingStatus.isPairing)
        XCTAssertFalse(model.selectQRCodePairingServiceIfAvailable())

        model.updateDiscoveredServices([unrelatedService, matchingService])

        XCTAssertTrue(model.selectQRCodePairingServiceIfAvailable())
        XCTAssertEqual(model.pairingDraft.discoveredService, matchingService)
        XCTAssertTrue(model.pairingDraft.canStartDiscoveredQRPairing)
        XCTAssertTrue(model.pairingDraft.canStartPairing)
    }

    func testInvalidQRCodeStoresUserAndTechnicalError() {
        var model = ADBTVAppModel()

        model.prepareQRCodePairing(payload: "WIFI:T:WPA;S:Network;P:secret;;")

        guard case let .failed(userMessage, diagnosticDetail) = model.pairingStatus else {
            return XCTFail("Expected an invalid QR failure.")
        }
        XCTAssertEqual(userMessage, "This is not an Android pairing QR code.")
        XCTAssertEqual(diagnosticDetail.context["operation"], "parsePairingQRCode")
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

    func testPairingConnectionVerificationSavesOnlyMatchingVerifiedDevice() {
        var model = ADBTVAppModel()
        let candidate = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 5555
        )
        var verifiedDevice = candidate
        verifiedDevice.model = "Chromecast"
        model.beginPairingConnectionVerification(device: candidate)

        XCTAssertFalse(model.finishPairingConnectionVerification(
            expectedDeviceID: UUID(),
            verifiedDevice: verifiedDevice
        ))
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertEqual(model.pairingStatus, .verifyingConnection(candidate))

        XCTAssertTrue(model.finishPairingConnectionVerification(
            expectedDeviceID: candidate.id,
            verifiedDevice: verifiedDevice
        ))
        XCTAssertEqual(model.devices, [verifiedDevice])
        XCTAssertEqual(model.selectedDevice, verifiedDevice)
        XCTAssertEqual(model.pairingStatus, .paired(verifiedDevice))
    }

    func testPairingConnectionVerificationFailureIgnoresStaleResult() {
        var model = ADBTVAppModel()
        let candidate = ADBTVDeviceSummary(
            displayName: "Living Room",
            host: "192.168.1.50",
            port: 5555
        )
        let diagnostic = DiagnosticDetail(
            summary: "connection refused",
            context: ["operation": "verifyPairedDevice"]
        )
        model.beginPairingConnectionVerification(device: candidate)

        XCTAssertFalse(model.failPairingConnectionVerification(
            expectedDeviceID: UUID(),
            userMessage: "Could not verify the TV connection.",
            diagnosticDetail: diagnostic
        ))
        XCTAssertEqual(model.pairingStatus, .verifyingConnection(candidate))

        XCTAssertTrue(model.failPairingConnectionVerification(
            expectedDeviceID: candidate.id,
            userMessage: "Could not verify the TV connection.",
            diagnosticDetail: diagnostic
        ))
        XCTAssertEqual(model.pairingStatus, .failed(
            userMessage: "Could not verify the TV connection.",
            diagnosticDetail: diagnostic
        ))
        XCTAssertTrue(model.devices.isEmpty)
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
