struct ADBTVAutomaticDiscoveryPolicy: Equatable, Sendable {
    private(set) var hasEvaluatedLaunch = false

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
}
