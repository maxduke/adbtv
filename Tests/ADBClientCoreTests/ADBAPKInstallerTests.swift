import XCTest
@testable import ADBClientCore

final class ADBAPKInstallerTests: XCTestCase {
    func testInstallRunsPreparePushInstallAndCleanupInOrder() async throws {
        let plan = try ADBAPKInstallPlan.singleAPK(fileName: "Example App.apk", byteCount: 3)
        let transferEvents: [ADBSyncPushEvent] = [
            .started(remotePath: plan.remoteAPKPath, totalByteCount: 3),
            .progress(sentByteCount: 3, totalByteCount: 3),
            .finishedSending(sentByteCount: 3, totalByteCount: 3),
            .completed
        ]
        var session = RecordingAPKInstallSession(
            shellOutputs: [
                try plan.installShellCommand().rawValue: ADBShellOutput(bytes: Array("Success\n".utf8))
            ],
            pushedEvents: transferEvents
        )

        let eventRecorder = APKInstallEventRecorder()
        let report = try await ADBAPKInstaller().install(
            contents: [1, 2, 3],
            plan: plan,
            modificationTime: 123,
            using: &session,
            eventHandler: { event in
                await eventRecorder.record(event)
            }
        )
        let streamedEvents = await eventRecorder.recordedEvents()

        XCTAssertEqual(report.result, .success)
        XCTAssertEqual(session.commands, [
            try plan.prepareRemoteDirectoryShellCommand().rawValue,
            try plan.installShellCommand().rawValue,
            try plan.cleanupShellCommand().rawValue
        ])
        XCTAssertEqual(session.pushedContents, [[1, 2, 3]])
        XCTAssertEqual(session.pushedPlans, [
            try ADBSyncPushPlan(
                remotePath: plan.remoteAPKPath,
                modificationTime: 123,
                totalByteCount: 3
            )
        ])
        XCTAssertEqual(report.events, [
            .phaseStarted(.prepareRemoteDirectory),
            .phaseFinished(.prepareRemoteDirectory),
            .phaseStarted(.transferPackage),
            .transfer(transferEvents[0]),
            .transfer(transferEvents[1]),
            .transfer(transferEvents[2]),
            .transfer(transferEvents[3]),
            .phaseFinished(.transferPackage),
            .phaseStarted(.installPackage),
            .installResult(.success),
            .phaseFinished(.installPackage),
            .phaseStarted(.cleanup),
            .phaseFinished(.cleanup)
        ])
        XCTAssertEqual(streamedEvents, report.events)
    }

    func testInstallFailureOutputReturnsFailureReportAndStillCleansUp() async throws {
        let plan = try ADBAPKInstallPlan.singleAPK(fileName: "app.apk", byteCount: 0)
        var session = RecordingAPKInstallSession(
            shellOutputs: [
                try plan.installShellCommand().rawValue: ADBShellOutput(
                    bytes: Array("Failure [INSTALL_FAILED_ALREADY_EXISTS]\n".utf8)
                )
            ],
            pushedEvents: [
                .started(remotePath: plan.remoteAPKPath, totalByteCount: 0),
                .finishedSending(sentByteCount: 0, totalByteCount: 0),
                .completed
            ]
        )

        let report = try await ADBAPKInstaller().install(contents: [], plan: plan, using: &session)

        XCTAssertEqual(report.result, .failure(message: "INSTALL_FAILED_ALREADY_EXISTS"))
        XCTAssertEqual(session.commands, [
            try plan.prepareRemoteDirectoryShellCommand().rawValue,
            try plan.installShellCommand().rawValue,
            try plan.cleanupShellCommand().rawValue
        ])
        XCTAssertEqual(Array(report.events.suffix(4)), [
            .installResult(.failure(message: "INSTALL_FAILED_ALREADY_EXISTS")),
            .phaseFinished(.installPackage),
            .phaseStarted(.cleanup),
            .phaseFinished(.cleanup)
        ])
    }

    func testTransferFailureThrowsAndRunsCleanupWithoutInstall() async throws {
        let plan = try ADBAPKInstallPlan.singleAPK(fileName: "app.apk", byteCount: 2)
        let transferEvents: [ADBSyncPushEvent] = [
            .started(remotePath: plan.remoteAPKPath, totalByteCount: 2),
            .failed(message: "permission denied")
        ]
        var session = RecordingAPKInstallSession(pushedEvents: transferEvents)

        do {
            _ = try await ADBAPKInstaller().install(contents: [1, 2], plan: plan, using: &session)
            XCTFail("Expected transfer failure to throw.")
        } catch let error as ADBAPKInstallExecutionError {
            XCTAssertEqual(error, .transferFailed(message: "permission denied", events: [
                .phaseStarted(.prepareRemoteDirectory),
                .phaseFinished(.prepareRemoteDirectory),
                .phaseStarted(.transferPackage),
                .transfer(transferEvents[0]),
                .transfer(transferEvents[1]),
                .phaseStarted(.cleanup),
                .phaseFinished(.cleanup)
            ]))
        }

        XCTAssertEqual(session.commands, [
            try plan.prepareRemoteDirectoryShellCommand().rawValue,
            try plan.cleanupShellCommand().rawValue
        ])
    }

    func testInstallRejectsPackageByteCountMismatchBeforeCommands() async throws {
        let plan = try ADBAPKInstallPlan.singleAPK(fileName: "app.apk", byteCount: 4)
        var session = RecordingAPKInstallSession()

        do {
            _ = try await ADBAPKInstaller().install(contents: [1, 2, 3], plan: plan, using: &session)
            XCTFail("Expected byte count mismatch to throw.")
        } catch let error as ADBAPKInstallExecutionError {
            XCTAssertEqual(error, .packageByteCountMismatch(expected: 4, actual: 3))
        }

        XCTAssertEqual(session.commands, [])
        XCTAssertEqual(session.pushedContents, [])
    }
}

private struct RecordingAPKInstallSession: ADBAPKInstallRunningSession {
    var shellOutputs: [String: ADBShellOutput]
    var pushedEvents: [ADBSyncPushEvent]
    private(set) var commands: [String]
    private(set) var pushedContents: [[UInt8]]
    private(set) var pushedPlans: [ADBSyncPushPlan]

    init(
        shellOutputs: [String: ADBShellOutput] = [:],
        pushedEvents: [ADBSyncPushEvent] = []
    ) {
        self.shellOutputs = shellOutputs
        self.pushedEvents = pushedEvents
        self.commands = []
        self.pushedContents = []
        self.pushedPlans = []
    }

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        commands.append(command.rawValue)
        return shellOutputs[command.rawValue] ?? ADBShellOutput(bytes: [])
    }

    mutating func pushFile(
        contents: [UInt8],
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler
    ) async throws -> [ADBSyncPushEvent] {
        pushedContents.append(contents)
        pushedPlans.append(plan)
        for event in pushedEvents {
            await eventHandler(event)
        }
        return pushedEvents
    }
}

private actor APKInstallEventRecorder {
    private var events: [ADBAPKInstallEvent] = []

    func record(_ event: ADBAPKInstallEvent) {
        events.append(event)
    }

    func recordedEvents() -> [ADBAPKInstallEvent] {
        events
    }
}
