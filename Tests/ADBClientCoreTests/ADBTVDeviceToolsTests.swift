import Foundation
import XCTest
@testable import ADBClientCore

final class ADBTVDeviceToolsTests: XCTestCase {
    func testLoadsStaticAndBestEffortDeviceInformation() async throws {
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession(
            shellOutputs: [
                "getprop ro.product.manufacturer": "Sony\n",
                "getprop ro.product.model": "BRAVIA XR\n",
                "getprop ro.product.name": "bravia\n",
                "getprop ro.product.device": "bravia_atv\n",
                "getprop ro.build.version.release": "14\n",
                "getprop ro.build.version.sdk": "34\n",
                "getprop ro.build.fingerprint": "sony/bravia/release-keys\n",
                "wm size": "Physical size: 3840x2160\nOverride size: 1920x1080\n",
                "df -k /data": "Filesystem 1K-blocks Used Available Use% Mounted on\n/data 1000 400 600 40% /data\n",
                "cat /proc/uptime": "93784.25 1000.00\n"
            ]
        ))

        let information = try await tools.loadInformation(systemIdentity: "host::adbtv")

        XCTAssertEqual(information.device.manufacturer, "Sony")
        XCTAssertEqual(information.device.model, "BRAVIA XR")
        XCTAssertEqual(information.device.androidVersion, "14")
        XCTAssertEqual(information.displaySize, ADBTVDisplaySize(width: 1920, height: 1080))
        XCTAssertEqual(information.storage, ADBTVStorageInfo(
            totalByteCount: 1_024_000,
            usedByteCount: 409_600,
            availableByteCount: 614_400
        ))
        XCTAssertEqual(information.uptime, ADBTVUptime(seconds: 93_784.25))
        XCTAssertEqual(tools.session.connectIdentities, ["host::adbtv"])
    }

    func testDynamicInformationFailuresRemainBestEffort() async throws {
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession(
            shellOutputs: basicPropertyOutputs,
            failingCommands: ["wm size", "df -k /data", "cat /proc/uptime"]
        ))

        let information = try await tools.loadInformation()

        XCTAssertEqual(information.device.model, "Android TV")
        XCTAssertNil(information.displaySize)
        XCTAssertNil(information.storage)
        XCTAssertNil(information.uptime)
    }

    func testCapturesAndValidatesPNGUsingRawExecService() async throws {
        let png = testPNG()
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession(serviceOutput: png))

        let screenshot = try await tools.captureScreenshot()

        XCTAssertEqual(screenshot.pngData, Data(png))
        XCTAssertEqual(screenshot.width, 16)
        XCTAssertEqual(screenshot.height, 9)
        XCTAssertEqual(tools.session.services, ["exec:screencap -p"])
    }

    func testReportsRejectedScreenshotOutputWithoutTreatingItAsPNG() async {
        let response = Array("capture blocked\n".utf8)
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession(serviceOutput: response))

        do {
            _ = try await tools.captureScreenshot()
            XCTFail("Expected screenshot rejection.")
        } catch let error as ADBTVDeviceToolsError {
            XCTAssertEqual(
                error,
                .screenshotUnavailable(
                    outputByteCount: response.count,
                    deviceMessage: "capture blocked"
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReportsTruncatedPNGAsAnInvalidImageInsteadOfABlockedCapture() async {
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession(serviceOutput: Array(testPNG().dropLast())))
        do {
            _ = try await tools.captureScreenshot()
            XCTFail("Expected a truncated screenshot to fail.")
        } catch {
            XCTAssertEqual(error as? ADBTVDeviceToolsError, .invalidScreenshotPNG)
        }
    }

    func testRejectsInvalidScreenshotData() {
        XCTAssertThrowsError(try ADBTVScreenshot(pngData: Data("not a png".utf8))) { error in
            XCTAssertEqual(error as? ADBTVDeviceToolsError, .invalidScreenshotPNG)
        }
    }

    func testRejectsEveryTruncatedPrefixOfACompletePNG() {
        let png = testPNG()
        for length in 0..<png.count {
            XCTAssertThrowsError(try ADBTVScreenshot(pngData: Data(png.prefix(length))),
                                 "Accepted a truncated PNG of \(length) bytes")
        }
    }

    func testRejectsMissingImageDataDuplicateHeaderAndTrailingBytes() {
        let png = testPNG()
        let withoutImageData = Array(png.prefix(33)) + Array(png.suffix(12))
        let duplicateHeader = Array(png.prefix(33)) + Array(png[8..<33]) + Array(png.dropFirst(33))
        for invalid in [withoutImageData, duplicateHeader, png + [0]] {
            XCTAssertThrowsError(try ADBTVScreenshot(pngData: Data(invalid))) {
                XCTAssertEqual($0 as? ADBTVDeviceToolsError, .invalidScreenshotPNG)
            }
        }
    }

    func testRejectsChunkLengthsThatExceedTheResponseAndInvalidHeaderLength() {
        for offset in [8, 33] {
            var png = testPNG()
            png.replaceSubrange(offset..<(offset + 4), with: [255, 255, 255, 255])
            XCTAssertThrowsError(try ADBTVScreenshot(pngData: Data(png))) {
                XCTAssertEqual($0 as? ADBTVDeviceToolsError, .invalidScreenshotPNG)
            }
        }
    }

    func testRejectsDamagedHeaderPixelsAndEndMarkerChecksums() {
        let original = testPNG()
        for offset in [29, 41, original.count - 1] {
            var png = original
            png[offset] ^= 1
            XCTAssertThrowsError(try ADBTVScreenshot(pngData: Data(png))) {
                XCTAssertEqual($0 as? ADBTVDeviceToolsError, .invalidScreenshotPNG)
            }
        }
    }

    func testRunsOneShotShellAndPreservesNonzeroExitStatus() async throws {
        let shellOutput = "permission denied\n\n\(ADBCheckedShellInvocation.exitStatusMarker)1\n"
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession(
            serviceOutput: Array(shellOutput.utf8)
        ))

        let result = try await tools.runShellCommand("cat /data/secret")

        XCTAssertEqual(result.output.utf8String, "permission denied\n")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(tools.session.services.count, 1)
        XCTAssertTrue(tools.session.services[0].hasPrefix("shell:(\ncat /data/secret\n); "))
    }

    func testRejectsWhitespaceOnlyShellCommand() async {
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession())

        do {
            _ = try await tools.runShellCommand(" \n ")
            XCTFail("Expected an empty command failure.")
        } catch let error as ADBTVDeviceToolsError {
            XCTAssertEqual(error, .emptyShellCommand)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsOversizedShellCommandBeforeOpeningService() async {
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession())
        let oversizedCommand = String(
            repeating: "a",
            count: ADBTVDeviceTools<FakeDeviceToolsSession>.maximumShellCommandByteCount + 1
        )

        do {
            _ = try await tools.runShellCommand(oversizedCommand)
            XCTFail("Expected an oversized command failure.")
        } catch let error as ADBTVDeviceToolsError {
            XCTAssertEqual(
                error,
                .shellCommandTooLarge(
                    maximumByteCount: ADBTVDeviceTools<FakeDeviceToolsSession>
                        .maximumShellCommandByteCount
                )
            )
            XCTAssertTrue(tools.session.services.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestsSystemCacheTrimToDesiredFreeSpace() async throws {
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession())

        try await tools.trimCaches(desiredFreeByteCount: 32_000_000_000)

        XCTAssertEqual(tools.session.shellCommands.last, "pm trim-caches 32000000000")
    }

    func testRejectsInvalidCacheTrimTarget() async {
        var tools = ADBTVDeviceTools(session: FakeDeviceToolsSession())

        do {
            try await tools.trimCaches(desiredFreeByteCount: 0)
            XCTFail("Expected an invalid cache trim target.")
        } catch let error as ADBTVDeviceToolsError {
            XCTAssertEqual(error, .invalidDesiredFreeByteCount(0))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct FakeDeviceToolsSession: ADBDeviceToolsSession {
    var shellOutputs: [String: String]
    var failingCommands: Set<String>
    var serviceOutput: [UInt8]
    private(set) var connectIdentities: [String] = []
    private(set) var services: [String] = []
    private(set) var shellCommands: [String] = []

    init(
        shellOutputs: [String: String] = basicPropertyOutputs,
        failingCommands: Set<String> = [],
        serviceOutput: [UInt8] = []
    ) {
        self.shellOutputs = shellOutputs
        self.failingCommands = failingCommands
        self.serviceOutput = serviceOutput
    }

    mutating func connect(systemIdentity: String) async throws -> ADBConnectedDevice {
        connectIdentities.append(systemIdentity)
        return ADBConnectedDevice(protocolVersion: 1, maxData: 4096, banner: "device::")
    }

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        let original = try originalCommand(from: command.rawValue)
        shellCommands.append(original)
        if failingCommands.contains(original) {
            throw TestError.failedCommand
        }
        return checkedOutput(shellOutputs[original, default: ""])
    }

    mutating func runService(
        _ service: String,
        maximumOutputByteCount: Int
    ) async throws -> ADBServiceOutput {
        services.append(service)
        guard serviceOutput.count <= maximumOutputByteCount else {
            throw ADBDeviceSessionError.serviceOutputTooLarge(
                maximumByteCount: maximumOutputByteCount
            )
        }
        return ADBServiceOutput(bytes: serviceOutput)
    }

    private func originalCommand(from checkedCommand: String) throws -> String {
        guard checkedCommand.hasPrefix("(\n"),
              let separator = checkedCommand.range(of: "\n); __adbtv_status=$?", options: .backwards) else {
            throw TestError.invalidCheckedCommand
        }
        return String(checkedCommand.dropFirst(2)[..<separator.lowerBound])
    }
}

private let basicPropertyOutputs: [String: String] = [
    "getprop ro.product.manufacturer": "Google\n",
    "getprop ro.product.model": "Android TV\n",
    "getprop ro.product.name": "atv\n",
    "getprop ro.product.device": "atv\n",
    "getprop ro.build.version.release": "12\n",
    "getprop ro.build.version.sdk": "31\n",
    "getprop ro.build.fingerprint": "google/atv/release-keys\n"
]

private func checkedOutput(_ value: String, exitCode: Int = 0) -> ADBShellOutput {
    ADBShellOutput(bytes: Array(
        (value + "\n\(ADBCheckedShellInvocation.exitStatusMarker)\(exitCode)\n").utf8
    ))
}

private func testPNG() -> [UInt8] {
    Array(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAFklEQVR4nGNQLrjznxLMMGrAqAFADAAEGl3wf2IiSgAAAABJRU5ErkJggg==")!)
}

private enum TestError: Error {
    case failedCommand
    case invalidCheckedCommand
}
