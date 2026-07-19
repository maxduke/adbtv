enum ADBTVTimedOperation: String, Equatable, Sendable {
    case deviceConnection
    case savedDeviceVerification
    case manualDeviceVerification
    case pairingConnectionVerification
    case pairing
    case pairingServiceDiscovery
    case connectionServiceDiscovery
    case remoteAction
    case installedApps
    case deviceInformation
    case screenshot
    case shellCommand
    case cacheCleanup
    case apkInstallation
    case apkStagingCleanup
    case packageSessionCleanup
}

enum ADBTVOperationTimeoutError: Error, Equatable, Sendable {
    case timedOut(operation: ADBTVTimedOperation, seconds: Int)
}

struct ADBTVOperationTimeout: Sendable {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    let seconds: Int
    private let sleep: Sleep

    init(
        seconds: Int,
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.seconds = seconds
        self.sleep = sleep
    }

    func run<Result: Sendable>(
        operation: ADBTVTimedOperation,
        _ work: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask(operation: work)
            group.addTask {
                try await sleep(.seconds(seconds))
                try Task.checkCancellation()
                throw ADBTVOperationTimeoutError.timedOut(
                    operation: operation,
                    seconds: seconds
                )
            }
            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    func waitUntilTimedOut(operation: ADBTVTimedOperation) async throws -> Never {
        try await sleep(.seconds(seconds))
        try Task.checkCancellation()
        throw ADBTVOperationTimeoutError.timedOut(
            operation: operation,
            seconds: seconds
        )
    }
}

enum ADBTVOperationTimeoutPolicy {
    static let deviceConnection = ADBTVOperationTimeout(seconds: 30)
    static let savedDeviceVerification = ADBTVOperationTimeout(seconds: 10)
    static let manualDeviceVerification = ADBTVOperationTimeout(seconds: 45)
    static let pairingConnectionVerification = ADBTVOperationTimeout(seconds: 45)
    static let pairing = ADBTVOperationTimeout(seconds: 90)
    static let pairingServiceDiscovery = ADBTVOperationTimeout(seconds: 45)
    static let connectionServiceDiscovery = ADBTVOperationTimeout(seconds: 45)
    static let remoteAction = ADBTVOperationTimeout(seconds: 8)
    static let installedApps = ADBTVOperationTimeout(seconds: 30)
    static let deviceInformation = ADBTVOperationTimeout(seconds: 45)
    static let screenshot = ADBTVOperationTimeout(seconds: 30)
    static let shellCommand = ADBTVOperationTimeout(seconds: 60)
    static let cacheCleanup = ADBTVOperationTimeout(seconds: 2 * 60)
    static let apkInstallation = ADBTVOperationTimeout(seconds: 15 * 60)
    static let apkStagingCleanup = ADBTVOperationTimeout(seconds: 45)
    static let packageSessionCleanup = ADBTVOperationTimeout(seconds: 45)
}
