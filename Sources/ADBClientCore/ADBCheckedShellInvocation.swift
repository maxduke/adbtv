public struct ADBCheckedShellInvocation: Equatable, Sendable {
    static let exitStatusMarker = "__ADBTV_EXIT_STATUS__="
    static let maximumDiagnosticByteCount = 4 * 1024

    public var shellCommand: ADBShellCommand

    public init(command: ADBShellCommand) throws {
        shellCommand = try ADBShellCommand(
            "(\n\(command.rawValue)\n); "
                + "__adbtv_status=$?; "
                + "printf '\\n\(Self.exitStatusMarker)%s\\n' \"$__adbtv_status\""
        )
    }

    public func validatedOutput(from output: ADBShellOutput) throws -> ADBShellOutput {
        let result = try result(from: output)
        guard result.exitCode == 0 else {
            throw ADBCheckedShellInvocationError.commandFailed(
                exitCode: result.exitCode,
                output: diagnosticOutput(from: result.output.bytes)
            )
        }
        return result.output
    }

    public func result(from output: ADBShellOutput) throws -> ADBCheckedShellResult {
        let marker = Array(("\n" + Self.exitStatusMarker).utf8)
        guard let markerIndex = lastIndex(of: marker, in: output.bytes) else {
            throw ADBCheckedShellInvocationError.missingExitStatus(
                output: diagnosticOutput(from: output.bytes)
            )
        }

        let statusStart = markerIndex + marker.count
        let statusBytes = output.bytes[statusStart...].prefix { byte in
            byte != 10 && byte != 13
        }
        guard let exitCode = Int(String(decoding: statusBytes, as: UTF8.self)),
              (0 ... 255).contains(exitCode) else {
            throw ADBCheckedShellInvocationError.invalidExitStatus(
                String(decoding: statusBytes, as: UTF8.self)
            )
        }

        let commandOutput = Array(output.bytes[..<markerIndex])
        return ADBCheckedShellResult(
            output: ADBShellOutput(bytes: commandOutput),
            exitCode: exitCode
        )
    }

    private func lastIndex(of marker: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !marker.isEmpty, bytes.count >= marker.count else {
            return nil
        }

        for index in stride(from: bytes.count - marker.count, through: 0, by: -1) {
            if bytes[index ..< index + marker.count].elementsEqual(marker) {
                return index
            }
        }
        return nil
    }

    private func diagnosticOutput(from bytes: [UInt8]) -> String {
        let prefix = bytes.prefix(Self.maximumDiagnosticByteCount)
        let value = String(decoding: prefix, as: UTF8.self)
        return bytes.count > prefix.count ? value + " [truncated]" : value
    }
}

public struct ADBCheckedShellResult: Equatable, Sendable {
    public var output: ADBShellOutput
    public var exitCode: Int

    public init(output: ADBShellOutput, exitCode: Int) {
        self.output = output
        self.exitCode = exitCode
    }
}

public enum ADBCheckedShellInvocationError: Error, Equatable, Sendable {
    case missingExitStatus(output: String)
    case invalidExitStatus(String)
    case commandFailed(exitCode: Int, output: String)
}
