import XCTest
@testable import ADBClientCore

final class ADBDeviceProbeTests: XCTestCase {
    func testConnectAndReadDeviceInfoConnectsAndRunsExpectedGetpropCommands() async throws {
        var probe = ADBDeviceProbe(session: FakeDeviceProbingSession(
            propertyOutputs: [
                "getprop ro.product.manufacturer": "Sony\n",
                "getprop ro.product.model": "BRAVIA 4K VH2\r\n",
                "getprop ro.product.name": "atv\n",
                "getprop ro.product.device": "bravia_atv\n",
                "getprop ro.build.version.release": "12\n",
                "getprop ro.build.version.sdk": "31\n",
                "getprop ro.build.fingerprint": "sony/bravia/user/release-keys\n"
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
            "getprop ro.product.manufacturer",
            "getprop ro.product.model",
            "getprop ro.product.name",
            "getprop ro.product.device",
            "getprop ro.build.version.release",
            "getprop ro.build.version.sdk",
            "getprop ro.build.fingerprint"
        ])
    }

    func testReadPropertyTrimsWhitespaceAndNewlines() async throws {
        var probe = ADBDeviceProbe(session: FakeDeviceProbingSession(
            propertyOutputs: [
                "getprop ro.product.model": "  Chromecast HD \r\n"
            ]
        ))

        let model = try await probe.readProperty(.model)

        XCTAssertEqual(model, "Chromecast HD")
    }

    func testDevicePropertyBuildsSafeGetpropShellCommand() throws {
        let command = try ADBDeviceProperty.androidVersion.shellCommand()

        XCTAssertEqual(command.rawValue, "getprop ro.build.version.release")
        XCTAssertEqual(command.serviceName, "shell:getprop ro.build.version.release")
    }
}

private struct FakeDeviceProbingSession: ADBDeviceProbingSession {
    var propertyOutputs: [String: String]
    private(set) var connectIdentities: [String]
    private(set) var commands: [String]

    init(propertyOutputs: [String: String]) {
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
        let value = propertyOutputs[command.rawValue, default: ""]
        return ADBShellOutput(bytes: Array(value.utf8))
    }
}
