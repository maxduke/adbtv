public protocol ADBAPKInstallRunningSession: ADBShellCommandRunningSession {
    mutating func pushFile(contents: [UInt8], plan: ADBSyncPushPlan) async throws -> [ADBSyncPushEvent]
}

extension ADBDeviceSession: ADBAPKInstallRunningSession {}

public struct ADBAPKInstaller: Sendable {
    public init() {}

    public func install<Session: ADBAPKInstallRunningSession>(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32 = 0,
        using session: inout Session
    ) async throws -> ADBAPKInstallReport {
        if let expectedByteCount = plan.package.byteCount, expectedByteCount != Int64(contents.count) {
            throw ADBAPKInstallExecutionError.packageByteCountMismatch(
                expected: expectedByteCount,
                actual: contents.count
            )
        }

        var events: [ADBAPKInstallEvent] = []

        events.append(.phaseStarted(.prepareRemoteDirectory))
        _ = try await session.runShellCommand(plan.prepareRemoteDirectoryShellCommand())
        events.append(.phaseFinished(.prepareRemoteDirectory))

        events.append(.phaseStarted(.transferPackage))
        let syncPlan = try ADBSyncPushPlan(
            remotePath: plan.remoteAPKPath,
            modificationTime: modificationTime,
            totalByteCount: contents.count
        )

        let syncEvents: [ADBSyncPushEvent]
        do {
            syncEvents = try await session.pushFile(contents: contents, plan: syncPlan)
        } catch {
            await runCleanupBestEffort(plan: plan, using: &session, events: &events)
            throw ADBAPKInstallExecutionError.transferCommandFailed(
                events: events,
                underlyingError: String(describing: error)
            )
        }

        events.append(contentsOf: syncEvents.map(ADBAPKInstallEvent.transfer))
        if let transferFailure = syncEvents.compactMap({ $0.failureMessage }).first {
            await runCleanupBestEffort(plan: plan, using: &session, events: &events)
            throw ADBAPKInstallExecutionError.transferFailed(message: transferFailure, events: events)
        }
        events.append(.phaseFinished(.transferPackage))

        events.append(.phaseStarted(.installPackage))
        let installOutput: ADBShellOutput
        do {
            installOutput = try await session.runShellCommand(plan.installShellCommand())
        } catch {
            await runCleanupBestEffort(plan: plan, using: &session, events: &events)
            throw ADBAPKInstallExecutionError.installCommandFailed(
                events: events,
                underlyingError: String(describing: error)
            )
        }

        let installResult = ADBAPKInstallResult.parse(shellOutput: installOutput)
        events.append(.installResult(installResult))
        events.append(.phaseFinished(.installPackage))

        do {
            try await runCleanup(plan: plan, using: &session, events: &events)
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
        events: inout [ADBAPKInstallEvent]
    ) async throws {
        events.append(.phaseStarted(.cleanup))
        _ = try await session.runShellCommand(plan.cleanupShellCommand())
        events.append(.phaseFinished(.cleanup))
    }

    private func runCleanupBestEffort<Session: ADBAPKInstallRunningSession>(
        plan: ADBAPKInstallPlan,
        using session: inout Session,
        events: inout [ADBAPKInstallEvent]
    ) async {
        do {
            try await runCleanup(plan: plan, using: &session, events: &events)
        } catch {}
    }
}

public extension ADBDeviceSession {
    mutating func installAPK(
        contents: [UInt8],
        plan: ADBAPKInstallPlan,
        modificationTime: UInt32 = 0,
        installer: ADBAPKInstaller = ADBAPKInstaller()
    ) async throws -> ADBAPKInstallReport {
        try await installer.install(
            contents: contents,
            plan: plan,
            modificationTime: modificationTime,
            using: &self
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

public enum ADBAPKInstallExecutionError: Error, Equatable, Sendable {
    case packageByteCountMismatch(expected: Int64, actual: Int)
    case transferFailed(message: String, events: [ADBAPKInstallEvent])
    case transferCommandFailed(events: [ADBAPKInstallEvent], underlyingError: String)
    case installCommandFailed(events: [ADBAPKInstallEvent], underlyingError: String)
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
