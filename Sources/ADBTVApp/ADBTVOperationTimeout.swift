enum ADBTVTimedOperation: String, Equatable, Sendable {
    case deviceConnection
    case manualDeviceVerification
    case pairing
    case pairingServiceDiscovery
    case connectionServiceDiscovery
    case remoteAction
    case apkInstallation
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
    static let manualDeviceVerification = ADBTVOperationTimeout(seconds: 45)
    static let pairing = ADBTVOperationTimeout(seconds: 90)
    static let pairingServiceDiscovery = ADBTVOperationTimeout(seconds: 45)
    static let connectionServiceDiscovery = ADBTVOperationTimeout(seconds: 45)
    static let remoteAction = ADBTVOperationTimeout(seconds: 20)
    static let apkInstallation = ADBTVOperationTimeout(seconds: 15 * 60)
}
