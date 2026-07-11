public protocol ADBAPKInstallRunningSession: ADBShellCommandRunningSession {
    mutating func pushFile(
        contents: [UInt8],
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler
    ) async throws -> [ADBSyncPushEvent]
}

public extension ADBAPKInstallRunningSession {
    mutating func pushFile(contents: [UInt8], plan: ADBSyncPushPlan) async throws -> [ADBSyncPushEvent] {
        try await pushFile(contents: contents, plan: plan, eventHandler: { _ in })
    }
}

extension ADBDeviceSession: ADBAPKInstallRunningSession {}

public struct ADBAPKInstaller: Sendable {
    public init() {}

    public func install<Session: ADBAPKInstallRunningSession>(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32 = 0,
        using session: inout Session,
        eventHandler: @escaping ADBAPKInstallEventHandler = { _ in }
    ) async throws -> ADBAPKInstallReport {
        if let expectedByteCount = plan.package.byteCount, expectedByteCount != Int64(contents.count) {
            throw ADBAPKInstallExecutionError.packageByteCountMismatch(
                expected: expectedByteCount,
                actual: contents.count
            )
        }
        try ADBAPKValidator().validate(contents: contents)

        var events: [ADBAPKInstallEvent] = []

        let prepareStarted = ADBAPKInstallEvent.phaseStarted(.prepareRemoteDirectory)
        events.append(prepareStarted)
        await eventHandler(prepareStarted)
        do {
            let invocation = try plan.prepareRemoteDirectoryShellInvocation()
            let output = try await session.runShellCommand(invocation.shellCommand)
            _ = try invocation.validatedOutput(from: output)
        } catch {
            throw ADBAPKInstallExecutionError.prepareCommandFailed(
                events: events,
                underlyingError: String(describing: error)
            )
        }
        let prepareFinished = ADBAPKInstallEvent.phaseFinished(.prepareRemoteDirectory)
        events.append(prepareFinished)
        await eventHandler(prepareFinished)

        let transferStarted = ADBAPKInstallEvent.phaseStarted(.transferPackage)
        events.append(transferStarted)
        await eventHandler(transferStarted)
        let syncPlan = try ADBSyncPushPlan(
            remotePath: plan.remoteAPKPath,
            modificationTime: modificationTime,
            totalByteCount: contents.count
        )

        let syncEvents: [ADBSyncPushEvent]
        do {
            syncEvents = try await session.pushFile(
                contents: contents,
                plan: syncPlan,
                eventHandler: { event in
                    await eventHandler(.transfer(event))
                }
            )
        } catch {
            let cleanupError = await runCleanupBestEffort(
                plan: plan,
                using: &session,
                events: &events,
                eventHandler: eventHandler
            )
            throw ADBAPKInstallExecutionError.transferCommandFailed(
                events: events,
                underlyingError: String(describing: error),
                cleanupError: cleanupError
            )
        }

        events.append(contentsOf: syncEvents.map(ADBAPKInstallEvent.transfer))
        if let transferFailure = syncEvents.compactMap({ $0.failureMessage }).first {
            let cleanupError = await runCleanupBestEffort(
                plan: plan,
                using: &session,
                events: &events,
                eventHandler: eventHandler
            )
            throw ADBAPKInstallExecutionError.transferFailed(
                message: transferFailure,
                events: events,
                cleanupError: cleanupError
            )
        }
        let transferFinished = ADBAPKInstallEvent.phaseFinished(.transferPackage)
        events.append(transferFinished)
        await eventHandler(transferFinished)

        let installStarted = ADBAPKInstallEvent.phaseStarted(.installPackage)
        events.append(installStarted)
        await eventHandler(installStarted)
        let installOutput: ADBShellOutput
        do {
            installOutput = try await session.runShellCommand(plan.installShellCommand())
        } catch {
            let cleanupError = await runCleanupBestEffort(
                plan: plan,
                using: &session,
                events: &events,
                eventHandler: eventHandler
            )
            throw ADBAPKInstallExecutionError.installCommandFailed(
                events: events,
                underlyingError: String(describing: error),
                cleanupError: cleanupError
            )
        }

        let installResult = ADBAPKInstallResult.parse(shellOutput: installOutput)
        let resultEvent = ADBAPKInstallEvent.installResult(installResult)
        events.append(resultEvent)
        await eventHandler(resultEvent)
        let installFinished = ADBAPKInstallEvent.phaseFinished(.installPackage)
        events.append(installFinished)
        await eventHandler(installFinished)

        do {
            try await runCleanup(
                plan: plan,
                using: &session,
                events: &events,
                eventHandler: eventHandler
            )
        } catch {
            throw ADBAPKInstallExecutionError.cleanupFailed(
                result: installResult,
                events: events,
                underlyingError: String(describing: error)
            )
        }

        return ADBAPKInstallReport(plan: plan, result: installResult, events: events)
    }

    private func runCleanup<Session: ADBAPKInstallRunningSession>(
        plan: ADBAPKInstallPlan,
        using session: inout Session,
        events: inout [ADBAPKInstallEvent],
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async throws {
        let cleanupStarted = ADBAPKInstallEvent.phaseStarted(.cleanup)
        events.append(cleanupStarted)
        await eventHandler(cleanupStarted)
        let invocation = try plan.cleanupShellInvocation()
        let output = try await session.runShellCommand(invocation.shellCommand)
        _ = try invocation.validatedOutput(from: output)
        let cleanupFinished = ADBAPKInstallEvent.phaseFinished(.cleanup)
        events.append(cleanupFinished)
        await eventHandler(cleanupFinished)
    }

    private func runCleanupBestEffort<Session: ADBAPKInstallRunningSession>(
        plan: ADBAPKInstallPlan,
        using session: inout Session,
        events: inout [ADBAPKInstallEvent],
        eventHandler: @escaping ADBAPKInstallEventHandler
    ) async -> String? {
        do {
            try await runCleanup(
                plan: plan,
                using: &session,
                events: &events,
                eventHandler: eventHandler
            )
            return nil
        } catch {
            return String(describing: error)
        }
    }
}

public extension ADBDeviceSession {
    mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32 = 0,
        installer: ADBAPKInstaller = ADBAPKInstaller(),
        eventHandler: @escaping ADBAPKInstallEventHandler = { _ in }
    ) async throws -> ADBAPKInstallReport {
        try await installer.install(
            contents: contents,
            plan: plan,
            modificationTime: modificationTime,
            using: &self,
            eventHandler: eventHandler
        )
    }
}

public struct ADBAPKInstallReport: Equatable, Sendable {
    public var plan: ADBAPKInstallPlan
    public var result: ADBAPKInstallResult
    public var events: [ADBAPKInstallEvent]

    public init(plan: ADBAPKInstallPlan, result: ADBAPKInstallResult, events: [ADBAPKInstallEvent]) {
        self.plan = plan
        self.result = result
        self.events = events
    }
}

public enum ADBAPKInstallEvent: Equatable, Sendable {
    case phaseStarted(ADBAPKInstallPhase)
    case phaseFinished(ADBAPKInstallPhase)
    case transfer(ADBSyncPushEvent)
    case installResult(ADBAPKInstallResult)
}

public typealias ADBAPKInstallEventHandler = @Sendable (ADBAPKInstallEvent) async -> Void

public enum ADBAPKInstallExecutionError: Error, Equatable, Sendable {
    case packageByteCountMismatch(expected: Int64, actual: Int)
    case prepareCommandFailed(events: [ADBAPKInstallEvent], underlyingError: String)
    case transferFailed(
        message: String,
        events: [ADBAPKInstallEvent],
        cleanupError: String?
    )
    case transferCommandFailed(
        events: [ADBAPKInstallEvent],
        underlyingError: String,
        cleanupError: String?
    )
    case installCommandFailed(
        events: [ADBAPKInstallEvent],
        underlyingError: String,
        cleanupError: String?
    )
    case cleanupFailed(result: ADBAPKInstallResult, events: [ADBAPKInstallEvent], underlyingError: String)
}

private extension ADBSyncPushEvent {
    var failureMessage: String? {
        if case .failed(let message) = self {
            return message
        }

        return nil
    }
}
