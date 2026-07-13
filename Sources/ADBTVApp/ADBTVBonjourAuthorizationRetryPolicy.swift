struct ADBTVBonjourAuthorizationRetryPolicy: Equatable, Sendable {
    static let delaysInSeconds = [1, 2, 4, 8, 15]

    private(set) var attempt = 0

    mutating func nextDelayInSeconds() -> Int? {
        guard Self.delaysInSeconds.indices.contains(attempt) else {
            return nil
        }
        defer { attempt += 1 }
        return Self.delaysInSeconds[attempt]
    }

    mutating func reset() {
        attempt = 0
    }
}
