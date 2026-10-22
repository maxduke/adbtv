import XCTest
@testable import ADBClientCore

final class ADBDeviceProbeTests: XCTestCase {
    func testConnectAndReadDeviceInfoConnectsAndRunsExpectedGetpropCommands() async throws {
        var probe = ADBDeviceProbe(session: FakeDeviceProbingSession(
            propertyOutputs: [
                .manufacturer: checkedPropertyOutput("Sony\n"),
                .model: checkedPropertyOutput("BRAVIA 4K VH2\r\n"),
                .productName: checkedPropertyOutput("atv\n"),
                .deviceName: checkedPropertyOutput("bravia_atv\n"),
                .androidVersion: checkedPropertyOutput("12\n"),
                .sdkVersion: checkedPropertyOutput("31\n"),
                .buildFingerprint: checkedPropertyOutput("sony/bravia/user/release-keys\n")
            ]
        ))

        let info = try await probe.connectAndReadDeviceInfo(systemIdentity: "host::adbtv")

        XCTAssertEqual(info, ADBAndroidTVDeviceInfo(
            connectedDevice: ADBConnectedDevice(protocolVersion: 1, maxData: 4096, banner: "device::"),
            manufacturer: "Sony",
            model: "BRAVIA 4K VH2",
            productName: "atv",
            deviceName: "bravia_atv",
            androidVersion: "12",
            sdkVersion: "31",
            buildFingerprint: "sony/bravia/user/release-keys"
        ))
        XCTAssertEqual(probe.session.connectIdentities, ["host::adbtv"])
        XCTAssertEqual(probe.session.commands, [
            try ADBDeviceProperty.manufacturer.shellInvocation().shellCommand.rawValue,
            try ADBDeviceProperty.model.shellInvocation().shellCommand.rawValue,
            try ADBDeviceProperty.productName.shellInvocation().shellCommand.rawValue,
            try ADBDeviceProperty.deviceName.shellInvocation().shellCommand.rawValue,
            try ADBDeviceProperty.androidVersion.shellInvocation().shellCommand.rawValue,
            try ADBDeviceProperty.sdkVersion.shellInvocation().shellCommand.rawValue,
            try ADBDeviceProperty.buildFingerprint.shellInvocation().shellCommand.rawValue
        ])
    }

    func testReadPropertyTrimsWhitespaceAndNewlines() async throws {
        var probe = ADBDeviceProbe(session: FakeDeviceProbingSession(
            propertyOutputs: [
                .model: checkedPropertyOutput("  Chromecast HD \r\n")
            ]
        ))

        let model = try await probe.readProperty(.model)

        XCTAssertEqual(model, "Chromecast HD")
    }

    func testReadPropertyRejectsShellFailure() async throws {
        var probe = ADBDeviceProbe(session: FakeDeviceProbingSession(
            propertyOutputs: [
                .model: checkedPropertyOutput("getprop failed", exitCode: 1)
            ]
        ))

        do {
            _ = try await probe.readProperty(.model)
            XCTFail("Expected checked property command to fail.")
        } catch let error as ADBCheckedShellInvocationError {
            XCTAssertEqual(
                error,
                .commandFailed(exitCode: 1, output: "getprop failed")
            )
        }
    }

    func testDevicePropertyBuildsSafeGetpropShellCommand() throws {
        let command = try ADBDeviceProperty.androidVersion.shellCommand()

        XCTAssertEqual(command.rawValue, "getprop ro.build.version.release")
        XCTAssertEqual(command.serviceName, "shell:getprop ro.build.version.release")
        XCTAssertTrue(
            try ADBDeviceProperty.androidVersion
                .shellInvocation()
                .shellCommand
                .rawValue
                .hasPrefix("(\ngetprop ro.build.version.release\n); ")
        )
    }
}

private struct FakeDeviceProbingSession: ADBDeviceProbingSession {
    var propertyOutputs: [ADBDeviceProperty: ADBShellOutput]
    private(set) var connectIdentities: [String]
    private(set) var commands: [String]

    init(propertyOutputs: [ADBDeviceProperty: ADBShellOutput]) {
        self.propertyOutputs = propertyOutputs
        self.connectIdentities = []
        self.commands = []
    }

    mutating func connect(systemIdentity: String) async throws -> ADBConnectedDevice {
        connectIdentities.append(systemIdentity)
        return ADBConnectedDevice(protocolVersion: 1, maxData: 4096, banner: "device::")
    }

    mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        commands.append(command.rawValue)
        for property in ADBDeviceProperty.allCases {
            if try property.shellInvocation().shellCommand == command {
                return propertyOutputs[property] ?? checkedPropertyOutput("")
            }
        }
        return checkedPropertyOutput("")
    }
}

private func checkedPropertyOutput(
    _ commandOutput: String,
    exitCode: Int = 0
) -> ADBShellOutput {
    ADBShellOutput(bytes: Array(
        (commandOutput
            + "\n\(ADBCheckedShellInvocation.exitStatusMarker)\(exitCode)\n").utf8
    ))
}
