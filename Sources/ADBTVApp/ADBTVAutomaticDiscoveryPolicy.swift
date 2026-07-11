struct ADBTVAutomaticDiscoveryPolicy: Equatable, Sendable {
    private(set) var hasEvaluatedLaunch = false
    private(set) var isDiscoverySuspended = false

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
}
