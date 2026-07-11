public struct UserFacingADBError: Error, Equatable, Sendable {
    public var userMessage: String
    public var diagnosticDetail: DiagnosticDetail

    public init(userMessage: String, diagnosticDetail: DiagnosticDetail) {
        self.userMessage = userMessage
        self.diagnosticDetail = diagnosticDetail
    }
}

public struct DiagnosticDetail: Equatable, Sendable {
    public var summary: String
    public var context: [String: String]

    public init(summary: String, context: [String: String] = [:]) {
        self.summary = summary
        self.context = context
    }

    public var formattedDescription: String {
        ([summary] + context.keys.sorted().map { key in
            "\(key): \(context[key] ?? "")"
        }).joined(separator: "\n")
    }
}
