import Foundation

public struct ADBPairingCode: Equatable, Sendable {
    public static let requiredDigitCount = 6

    public var rawValue: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.filter { !$0.isWhitespace && $0 != "-" }

        guard normalized.count == Self.requiredDigitCount else {
            throw ADBPairingCodeError.invalidDigitCount(normalized.count)
        }

        guard normalized.allSatisfy(\.isNumber) else {
            throw ADBPairingCodeError.containsNonDigit
        }

        self.rawValue = normalized
    }
}

public enum ADBPairingCodeError: Error, Equatable, Sendable {
    case invalidDigitCount(Int)
    case containsNonDigit
}

public struct ADBPairingQRCode: Equatable, Sendable {
    public var serviceName: String
    public var password: String

    public init(serviceName: String, password: String) throws {
        guard !serviceName.isEmpty else {
            throw ADBPairingQRCodeError.missingServiceName
        }

        guard !password.isEmpty else {
            throw ADBPairingQRCodeError.missingPassword
        }

        self.serviceName = serviceName
        self.password = password
    }

    public init(payload: String) throws {
        let fields = try ADBPairingQRCodeFields(payload: payload)

        guard fields.authenticationType == "ADB" else {
            throw ADBPairingQRCodeError.unsupportedAuthenticationType(fields.authenticationType)
        }

        try self.init(serviceName: fields.serviceName, password: fields.password)
    }
}

public enum ADBPairingQRCodeError: Error, Equatable, Sendable {
    case unsupportedFormat
    case unsupportedAuthenticationType(String?)
    case missingServiceName
    case missingPassword
}

private struct ADBPairingQRCodeFields {
    var authenticationType: String?
    var serviceName: String
    var password: String

    init(payload: String) throws {
        guard payload.hasPrefix("WIFI:") else {
            throw ADBPairingQRCodeError.unsupportedFormat
        }

        var values: [String: String] = [:]
        for field in Self.splitEscapedFields(String(payload.dropFirst("WIFI:".count))) {
            guard !field.isEmpty, let separator = Self.firstUnescapedSeparator(in: field) else {
                continue
            }

            let key = String(field[..<separator])
            let valueStart = field.index(after: separator)
            values[key] = Self.unescape(String(field[valueStart...]))
        }

        self.authenticationType = values["T"]
        self.serviceName = values["S", default: ""]
        self.password = values["P", default: ""]
    }

    private static func splitEscapedFields(_ value: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append("\\")
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == ";" {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        if isEscaped {
            current.append("\\")
        }
        if !current.isEmpty {
            fields.append(current)
        }

        return fields
    }

    private static func firstUnescapedSeparator(in value: String) -> String.Index? {
        var isEscaped = false

        for index in value.indices {
            let character = value[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == ":" {
                return index
            }
        }

        return nil
    }

    private static func unescape(_ value: String) -> String {
        var output = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                output.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                output.append(character)
            }
        }

        if isEscaped {
            output.append("\\")
        }

        return output
    }
}
