import Foundation
import XCTest
@testable import ADBClientCore

final class ADBAPKInstallerTests: XCTestCase {
    func testInstallRunsPreparePushInstallAndCleanupInOrder() async throws {
        let contents = makeTestAPK()
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "Example App.apk",
            byteCount: Int64(contents.count)
        )
        let transferEvents: [ADBSyncPushEvent] = [
            .started(remotePath: plan.remoteAPKPath, totalByteCount: contents.count),
            .progress(sentByteCount: contents.count, totalByteCount: contents.count),
            .finishedSending(sentByteCount: contents.count, totalByteCount: contents.count),
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
            contents: contents,
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
            try plan.prepareRemoteDirectoryShellInvocation().shellCommand.rawValue,
            try plan.installShellCommand().rawValue,
            try plan.cleanupShellInvocation().shellCommand.rawValue
        ])
        XCTAssertEqual(session.pushedContents, [contents])
        XCTAssertEqual(session.pushedPlans, [
            try ADBSyncPushPlan(
                remotePath: plan.remoteAPKPath,
                modificationTime: 123,
                totalByteCount: contents.count
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

    func testFileBackedInstallStreamsTheFileThroughTheSameStagedFlow() async throws {
        let contents = makeTestAPK()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBAPKInstallerTests-\(UUID().uuidString).apk")
        try Data(contents).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "Example App.apk",
            byteCount: Int64(contents.count)
        )
        let transferEvents: [ADBSyncPushEvent] = [
            .started(remotePath: plan.remoteAPKPath, totalByteCount: contents.count),
            .finishedSending(sentByteCount: contents.count, totalByteCount: contents.count),
            .completed
        ]
        var session = RecordingAPKInstallSession(
            shellOutputs: [
                try plan.installShellCommand().rawValue: ADBShellOutput(
                    bytes: Array("Success\n".utf8)
                )
            ],
            pushedEvents: transferEvents
        )

        let report = try await ADBAPKInstaller().install(
            fileURL: fileURL,
            plan: plan,
            modificationTime: 456,
            using: &session
        )

        XCTAssertEqual(report.result, .success)
        XCTAssertEqual(session.pushedFileURLs, [fileURL])
        XCTAssertEqual(session.pushedContents, [])
        XCTAssertEqual(session.pushedPlans, [
            try ADBSyncPushPlan(
                remotePath: plan.remoteAPKPath,
                modificationTime: 456,
                totalByteCount: contents.count
            )
        ])
        XCTAssertEqual(session.commands, [
            try plan.prepareRemoteDirectoryShellInvocation().shellCommand.rawValue,
            try plan.installShellCommand().rawValue,
            try plan.cleanupShellInvocation().shellCommand.rawValue
        ])
    }

    func testInstallFailureOutputReturnsFailureReportAndStillCleansUp() async throws {
        let contents = makeTestAPK()
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            byteCount: Int64(contents.count)
        )
        var session = RecordingAPKInstallSession(
            shellOutputs: [
                try plan.installShellCommand().rawValue: ADBShellOutput(
                    bytes: Array("Failure [INSTALL_FAILED_ALREADY_EXISTS]\n".utf8)
                )
            ],
            pushedEvents: [
                .started(remotePath: plan.remoteAPKPath, totalByteCount: contents.count),
                .finishedSending(sentByteCount: contents.count, totalByteCount: contents.count),
                .completed
            ]
        )

        let report = try await ADBAPKInstaller().install(contents: contents, plan: plan, using: &session)

        XCTAssertEqual(report.result, .failure(message: "INSTALL_FAILED_ALREADY_EXISTS"))
        XCTAssertEqual(session.commands, [
            try plan.prepareRemoteDirectoryShellInvocation().shellCommand.rawValue,
            try plan.installShellCommand().rawValue,
            try plan.cleanupShellInvocation().shellCommand.rawValue
        ])
        XCTAssertEqual(Array(report.events.suffix(4)), [
            .installResult(.failure(message: "INSTALL_FAILED_ALREADY_EXISTS")),
            .phaseFinished(.installPackage),
            .phaseStarted(.cleanup),
            .phaseFinished(.cleanup)
        ])
    }

    func testTransferFailureThrowsAndRunsCleanupWithoutInstall() async throws {
        let contents = makeTestAPK()
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            byteCount: Int64(contents.count)
        )
        let transferEvents: [ADBSyncPushEvent] = [
            .started(remotePath: plan.remoteAPKPath, totalByteCount: contents.count),
            .failed(message: "permission denied")
        ]
        var session = RecordingAPKInstallSession(pushedEvents: transferEvents)

        do {
            _ = try await ADBAPKInstaller().install(contents: contents, plan: plan, using: &session)
            XCTFail("Expected transfer failure to throw.")
        } catch let error as ADBAPKInstallExecutionError {
            XCTAssertEqual(
                error,
                .transferFailed(
                    message: "permission denied",
                    events: [
                        .phaseStarted(.prepareRemoteDirectory),
                        .phaseFinished(.prepareRemoteDirectory),
                        .phaseStarted(.transferPackage),
                        .transfer(transferEvents[0]),
                        .transfer(transferEvents[1]),
                        .phaseStarted(.cleanup),
                        .phaseFinished(.cleanup)
                    ],
                    cleanupError: nil
                )
            )
        }

        XCTAssertEqual(session.commands, [
            try plan.prepareRemoteDirectoryShellInvocation().shellCommand.rawValue,
            try plan.cleanupShellInvocation().shellCommand.rawValue
        ])
    }

    func testPrepareFailureStopsBeforeTransfer() async throws {
        let contents = makeTestAPK()
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            byteCount: Int64(contents.count)
        )
        let prepareCommand = try plan.prepareRemoteDirectoryShellInvocation().shellCommand.rawValue
        var session = RecordingAPKInstallSession(shellOutputs: [
            prepareCommand: checkedShellOutput("mkdir: Permission denied", exitCode: 1)
        ])

        do {
            _ = try await ADBAPKInstaller().install(contents: contents, plan: plan, using: &session)
            XCTFail("Expected preparation failure to throw.")
        } catch let error as ADBAPKInstallExecutionError {
            guard case let .prepareCommandFailed(events, underlyingError) = error else {
                return XCTFail("Expected prepareCommandFailed, got \(error).")
            }
            XCTAssertEqual(events, [.phaseStarted(.prepareRemoteDirectory)])
            XCTAssertTrue(underlyingError.contains("commandFailed(exitCode: 1"))
            XCTAssertTrue(underlyingError.contains("mkdir: Permission denied"))
        }

        XCTAssertEqual(session.commands, [prepareCommand])
        XCTAssertEqual(session.pushedContents, [])
    }

    func testCleanupExitFailureIsReportedAfterInstall() async throws {
        let contents = makeTestAPK()
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            byteCount: Int64(contents.count)
        )
        let cleanupCommand = try plan.cleanupShellInvocation().shellCommand.rawValue
        var session = RecordingAPKInstallSession(
            shellOutputs: [
                try plan.installShellCommand().rawValue: ADBShellOutput(
                    bytes: Array("Success\n".utf8)
                ),
                cleanupCommand: checkedShellOutput("rm: Permission denied", exitCode: 1)
            ],
            pushedEvents: [.completed]
        )

        do {
            _ = try await ADBAPKInstaller().install(contents: contents, plan: plan, using: &session)
            XCTFail("Expected cleanup failure to throw.")
        } catch let error as ADBAPKInstallExecutionError {
            guard case let .cleanupFailed(result, events, underlyingError) = error else {
                return XCTFail("Expected cleanupFailed, got \(error).")
            }
            XCTAssertEqual(result, .success)
            XCTAssertEqual(events.last, .phaseStarted(.cleanup))
            XCTAssertTrue(underlyingError.contains("commandFailed(exitCode: 1"))
            XCTAssertTrue(underlyingError.contains("rm: Permission denied"))
        }
    }

    func testTransferFailurePreservesCleanupFailureDetail() async throws {
        let contents = makeTestAPK()
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            byteCount: Int64(contents.count)
        )
        let cleanupCommand = try plan.cleanupShellInvocation().shellCommand.rawValue
        var session = RecordingAPKInstallSession(
            shellOutputs: [
                cleanupCommand: checkedShellOutput("rm failed", exitCode: 2)
            ],
            pushedEvents: [.failed(message: "push failed")]
        )

        do {
            _ = try await ADBAPKInstaller().install(contents: contents, plan: plan, using: &session)
            XCTFail("Expected transfer failure to throw.")
        } catch let error as ADBAPKInstallExecutionError {
            guard case let .transferFailed(message, events, cleanupError) = error else {
                return XCTFail("Expected transferFailed, got \(error).")
            }
            XCTAssertEqual(message, "push failed")
            XCTAssertEqual(events.last, .phaseStarted(.cleanup))
            XCTAssertTrue(cleanupError?.contains("commandFailed(exitCode: 2") == true)
            XCTAssertTrue(cleanupError?.contains("rm failed") == true)
        }
    }

    func testTransferCommandFailureRunsCleanupExactlyOnce() async throws {
        let contents = makeTestAPK()
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            byteCount: Int64(contents.count)
        )
        let cleanupCommand = try plan.cleanupShellInvocation().shellCommand.rawValue
        var session = RecordingAPKInstallSession(pushError: .pushFailed)

        do {
            _ = try await ADBAPKInstaller().install(contents: contents, plan: plan, using: &session)
            XCTFail("Expected transfer command failure to throw.")
        } catch let error as ADBAPKInstallExecutionError {
            guard case let .transferCommandFailed(events, underlyingError, cleanupError) = error else {
                return XCTFail("Expected transferCommandFailed, got \(error).")
            }
            XCTAssertEqual(Array(events.suffix(2)), [
                .phaseStarted(.cleanup),
                .phaseFinished(.cleanup)
            ])
            XCTAssertTrue(underlyingError.contains("pushFailed"))
            XCTAssertNil(cleanupError)
        }

        XCTAssertEqual(session.commands.filter { $0 == cleanupCommand }.count, 1)
    }

    func testStagingCleanerChecksRemoteRemovalExitStatus() async throws {
        let plan = try ADBAPKInstallPlan.singleAPK(fileName: "app.apk")
        let cleanupCommand = try plan.cleanupShellInvocation().shellCommand.rawValue
        var session = RecordingAPKInstallSession(shellOutputs: [
            cleanupCommand: checkedShellOutput("rm denied", exitCode: 1)
        ])

        do {
            try await ADBAPKStagingCleaner().cleanup(plan: plan, using: &session)
            XCTFail("Expected checked cleanup to fail.")
        } catch let error as ADBCheckedShellInvocationError {
            XCTAssertEqual(
                error,
                .commandFailed(exitCode: 1, output: "rm denied")
            )
        }
        XCTAssertEqual(session.commands, [cleanupCommand])
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

    func testFileBackedInstallRejectsPackageByteCountMismatchBeforeCommands() async throws {
        let contents = makeTestAPK()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBAPKInstallerTests-\(UUID().uuidString).apk")
        try Data(contents).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            byteCount: Int64(contents.count + 1)
        )
        var session = RecordingAPKInstallSession()

        do {
            _ = try await ADBAPKInstaller().install(
                fileURL: fileURL,
                plan: plan,
                using: &session
            )
            XCTFail("Expected byte count mismatch to throw.")
        } catch let error as ADBAPKInstallExecutionError {
            XCTAssertEqual(
                error,
                .packageByteCountMismatch(
                    expected: Int64(contents.count + 1),
                    actual: contents.count
                )
            )
        }

        XCTAssertEqual(session.commands, [])
        XCTAssertEqual(session.pushedFileURLs, [])
    }

    func testInstallRejectsInvalidAPKBeforeCommands() async throws {
        let contents = Array(repeating: UInt8(0), count: 22)
        let plan = try ADBAPKInstallPlan.singleAPK(
            fileName: "app.apk",
            byteCount: Int64(contents.count)
        )
        var session = RecordingAPKInstallSession()

        do {
            _ = try await ADBAPKInstaller().install(contents: contents, plan: plan, using: &session)
            XCTFail("Expected invalid APK to throw.")
        } catch let error as ADBAPKValidationError {
            XCTAssertEqual(error, .invalidZIPSignature)
        }

        XCTAssertEqual(session.commands, [])
        XCTAssertEqual(session.pushedContents, [])
    }
}

private struct RecordingAPKInstallSession: ADBAPKInstallRunningSession {
    var shellOutputs: [String: ADBShellOutput]
    var pushedEvents: [ADBSyncPushEvent]
    var pushError: RecordingAPKInstallSessionError?
    private(set) var commands: [String]
    private(set) var pushedContents: [[UInt8]]
    private(set) var pushedFileURLs: [URL]
    private(set) var pushedPlans: [ADBSyncPushPlan]

    init(
        shellOutputs: [String: ADBShellOutput] = [:],
        pushedEvents: [ADBSyncPushEvent] = [],
        pushError: RecordingAPKInstallSessionError? = nil
    ) {
        self.shellOutputs = shellOutputs
        self.pushedEvents = pushedEvents
        self.pushError = pushError
        self.commands = []
        self.pushedContents = []
        self.pushedFileURLs = []
        self.pushedPlans = []
    }

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        commands.append(command.rawValue)
        if let output = shellOutputs[command.rawValue] {
            return output
        }
        if command.rawValue.contains(ADBCheckedShellInvocation.exitStatusMarker) {
            return checkedShellOutput("")
        }
        return ADBShellOutput(bytes: [])
    }

    mutating func pushFile(
        from localURL: URL,
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler
    ) async throws -> [ADBSyncPushEvent] {
        pushedFileURLs.append(localURL)
        pushedPlans.append(plan)
        if let pushError {
            throw pushError
        }
        for event in pushedEvents {
            await eventHandler(event)
        }
        return pushedEvents
    }

    mutating func pushFile(
        contents: [UInt8],
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler
    ) async throws -> [ADBSyncPushEvent] {
        pushedContents.append(contents)
        pushedPlans.append(plan)
        if let pushError {
            throw pushError
        }
        for event in pushedEvents {
            await eventHandler(event)
        }
        return pushedEvents
    }
}

private enum RecordingAPKInstallSessionError: Error {
    case pushFailed
}

private func checkedShellOutput(
    _ commandOutput: String,
    exitCode: Int = 0
) -> ADBShellOutput {
    ADBShellOutput(bytes: Array(
        (commandOutput
            + "\n\(ADBCheckedShellInvocation.exitStatusMarker)\(exitCode)\n").utf8
    ))
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
