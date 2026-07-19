import Foundation

public protocol ADBDeviceToolsSession: ADBDeviceProbingSession {
    mutating func runService(
        _ service: String,
        maximumOutputByteCount: Int
    ) async throws -> ADBServiceOutput
}

extension ADBDeviceSession: ADBDeviceToolsSession {}

#if canImport(Network)
extension ADBDeviceConnection: ADBDeviceToolsSession {}
#endif

public struct ADBTVDeviceTools<Session: ADBDeviceToolsSession>: Sendable {
    public static var maximumScreenshotByteCount: Int { 32 * 1024 * 1024 }
    public static var maximumShellCommandByteCount: Int { 16 * 1024 }
    public static var maximumShellOutputByteCount: Int { 256 * 1024 }

    public private(set) var session: Session

    public init(session: Session) {
        self.session = session
    }

    public mutating func loadInformation(
        systemIdentity: String = "host::"
    ) async throws -> ADBTVDeviceInformation {
        var probe = ADBDeviceProbe(session: session)
        let device = try await probe.connectAndReadDeviceInfo(systemIdentity: systemIdentity)
        session = probe.session

        return ADBTVDeviceInformation(
            device: device,
            displaySize: try await bestEffortValue(
                command: "wm size",
                parse: ADBTVDisplaySize.parse
            ),
            storage: try await bestEffortValue(
                command: "df -k /data",
                parse: ADBTVStorageInfo.parse
            ),
            uptime: try await bestEffortValue(
                command: "cat /proc/uptime",
                parse: ADBTVUptime.parse
            )
        )
    }

    public mutating func captureScreenshot() async throws -> ADBTVScreenshot {
        let output = try await session.runService(
            "exec:screencap -p",
            maximumOutputByteCount: Self.maximumScreenshotByteCount
        )
        do {
            return try ADBTVScreenshot(pngData: Data(output.bytes))
        } catch ADBTVDeviceToolsError.invalidScreenshotPNG {
            throw ADBTVDeviceToolsError.screenshotUnavailable(
                outputByteCount: output.bytes.count,
                deviceMessage: Self.textPreview(output.bytes)
            )
        }
    }

    public mutating func runShellCommand(_ rawCommand: String) async throws -> ADBCheckedShellResult {
        guard !rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ADBTVDeviceToolsError.emptyShellCommand
        }
        guard rawCommand.utf8.count <= Self.maximumShellCommandByteCount else {
            throw ADBTVDeviceToolsError.shellCommandTooLarge(
                maximumByteCount: Self.maximumShellCommandByteCount
            )
        }

        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand(rawCommand)
        )
        let output = try await session.runService(
            invocation.shellCommand.serviceName,
            maximumOutputByteCount: Self.maximumShellOutputByteCount + 1024
        )
        let result = try invocation.result(from: ADBShellOutput(bytes: output.bytes))
        guard result.output.bytes.count <= Self.maximumShellOutputByteCount else {
            throw ADBTVDeviceToolsError.shellOutputTooLarge(
                maximumByteCount: Self.maximumShellOutputByteCount
            )
        }
        return result
    }

    public mutating func trimCaches(desiredFreeByteCount: Int64) async throws {
        guard desiredFreeByteCount > 0 else {
            throw ADBTVDeviceToolsError.invalidDesiredFreeByteCount(desiredFreeByteCount)
        }
        let invocation = try ADBCheckedShellInvocation(
            command: ADBShellCommand("pm trim-caches \(desiredFreeByteCount)")
        )
        let output = try await session.runShellCommand(invocation.shellCommand)
        _ = try invocation.validatedOutput(from: output)
    }

    private mutating func bestEffortValue<Value>(
        command: String,
        parse: (ADBShellOutput) -> Value?
    ) async throws -> Value? {
        do {
            let invocation = try ADBCheckedShellInvocation(command: ADBShellCommand(command))
            let output = try await session.runShellCommand(invocation.shellCommand)
            return parse(try invocation.validatedOutput(from: output))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func textPreview(_ bytes: [UInt8]) -> String? {
        let prefix = bytes.prefix(512)
        guard let value = String(bytes: prefix, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      || $0.value == 9 || $0.value == 10 || $0.value == 13
              }) else {
            return nil
        }
        return trimmed
    }
}

public struct ADBTVDeviceInformation: Equatable, Sendable {
    public var device: ADBAndroidTVDeviceInfo
    public var displaySize: ADBTVDisplaySize?
    public var storage: ADBTVStorageInfo?
    public var uptime: ADBTVUptime?

    public init(
        device: ADBAndroidTVDeviceInfo,
        displaySize: ADBTVDisplaySize? = nil,
        storage: ADBTVStorageInfo? = nil,
        uptime: ADBTVUptime? = nil
    ) {
        self.device = device
        self.displaySize = displaySize
        self.storage = storage
        self.uptime = uptime
    }
}

public struct ADBTVDisplaySize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    fileprivate static func parse(_ output: ADBShellOutput) -> Self? {
        var physical: Self?
        var override: Self?

        for line in output.utf8String.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let size = parseDimensions(String(parts[1])) else {
                continue
            }
            if parts[0].contains("Override") {
                override = size
            } else if parts[0].contains("Physical") {
                physical = size
            }
        }
        return override ?? physical
    }

    private static func parseDimensions(_ value: String) -> Self? {
        let dimensions = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
        guard dimensions.count == 2,
              let width = Int(dimensions[0]),
              let height = Int(dimensions[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return Self(width: width, height: height)
    }
}

public struct ADBTVStorageInfo: Equatable, Sendable {
    public var totalByteCount: Int64
    public var usedByteCount: Int64
    public var availableByteCount: Int64

    public init(totalByteCount: Int64, usedByteCount: Int64, availableByteCount: Int64) {
        self.totalByteCount = totalByteCount
        self.usedByteCount = usedByteCount
        self.availableByteCount = availableByteCount
    }

    fileprivate static func parse(_ output: ADBShellOutput) -> Self? {
        for line in output.utf8String.split(whereSeparator: \.isNewline).reversed() {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 4,
                  let total = Int64(columns[1]),
                  let used = Int64(columns[2]),
                  let available = Int64(columns[3]),
                  total >= 0,
                  used >= 0,
                  available >= 0,
                  total <= Int64.max / 1024,
                  used <= Int64.max / 1024,
                  available <= Int64.max / 1024 else {
                continue
            }
            return Self(
                totalByteCount: total * 1024,
                usedByteCount: used * 1024,
                availableByteCount: available * 1024
            )
        }
        return nil
    }
}

public struct ADBTVUptime: Equatable, Sendable {
    public var seconds: TimeInterval

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    fileprivate static func parse(_ output: ADBShellOutput) -> Self? {
        guard let value = output.utf8String.split(whereSeparator: \.isWhitespace).first,
              let seconds = TimeInterval(value),
              seconds >= 0 else {
            return nil
        }
        return Self(seconds: seconds)
    }
}

public struct ADBTVScreenshot: Equatable, Sendable {
    public var pngData: Data
    public var width: Int
    public var height: Int

    public init(pngData: Data) throws {
        guard pngData.count <= ADBTVDeviceTools<ADBDeviceSession>.maximumScreenshotByteCount else {
            throw ADBTVDeviceToolsError.screenshotTooLarge(pngData.count)
        }

        let header = [UInt8](pngData.prefix(24))
        guard header.count == 24,
              Array(header[0 ..< 8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(header[12 ..< 16]) == Array("IHDR".utf8) else {
            throw ADBTVDeviceToolsError.invalidScreenshotPNG
        }

        let width = Self.pngDimension(header[16 ..< 20])
        let height = Self.pngDimension(header[20 ..< 24])
        guard (1 ... 16_384).contains(width), (1 ... 16_384).contains(height) else {
            throw ADBTVDeviceToolsError.invalidScreenshotDimensions(width: width, height: height)
        }

        self.pngData = pngData
        self.width = width
        self.height = height
    }

    private static func pngDimension(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }
}

public enum ADBTVDeviceToolsError: Error, Equatable, Sendable {
    case invalidDesiredFreeByteCount(Int64)
    case emptyShellCommand
    case shellCommandTooLarge(maximumByteCount: Int)
    case shellOutputTooLarge(maximumByteCount: Int)
    case screenshotTooLarge(Int)
    case screenshotUnavailable(outputByteCount: Int, deviceMessage: String?)
    case invalidScreenshotPNG
    case invalidScreenshotDimensions(width: Int, height: Int)
}
