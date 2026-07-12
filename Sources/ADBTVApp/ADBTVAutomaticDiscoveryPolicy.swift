struct ADBTVAutomaticDiscoveryPolicy: Equatable, Sendable {
    private(set) var hasEvaluatedLaunch = false
    private(set) var isDiscoverySuspended = false
    private(set) var hasPendingAuthorizationRetry = false
    private(set) var hasRetriedAuthorizationFailureSinceActivation = false

    mutating func shouldStartDiscovery(status: ADBTVDiscoveryStatus) -> Bool {
        guard !hasEvaluatedLaunch else {
            return false
        }
        hasEvaluatedLaunch = true

        if case .idle = status {
            return true
        }
        return false
    }

    mutating func shouldSuspendDiscovery(status: ADBTVDiscoveryStatus) -> Bool {
        guard status.isBrowsing else {
            return false
        }

        isDiscoverySuspended = true
        return true
    }

    mutating func shouldResumeDiscovery(status: ADBTVDiscoveryStatus) -> Bool {
        guard isDiscoverySuspended else {
            return false
        }
        isDiscoverySuspended = false

        if case .idle = status {
            return true
        }
        return false
    }

    mutating func recordAuthorizationFailure() {
        hasPendingAuthorizationRetry = true
    }

    mutating func recordDiscoveryReady() {
        hasPendingAuthorizationRetry = false
        hasRetriedAuthorizationFailureSinceActivation = false
    }

    mutating func recordSceneLeftActiveState() {
        hasRetriedAuthorizationFailureSinceActivation = false
    }

    mutating func shouldRetryAuthorizationFailureAfterActivation(
        status: ADBTVDiscoveryStatus
    ) -> Bool {
        guard hasPendingAuthorizationRetry,
              !hasRetriedAuthorizationFailureSinceActivation else {
            return false
        }
        hasPendingAuthorizationRetry = false

        if case .failed = status {
            hasRetriedAuthorizationFailureSinceActivation = true
            return true
        }
        return false
    }
}
