import Foundation

public protocol ADBDeviceProbingSession: ADBShellCommandRunningSession {
    mutating func connect(systemIdentity: String) async throws -> ADBConnectedDevice
}

extension ADBDeviceSession: ADBDeviceProbingSession {}

public struct ADBDeviceProbe<Session: ADBDeviceProbingSession>: Sendable {
    public private(set) var session: Session

    public init(session: Session) {
        self.session = session
    }

    public mutating func connectAndReadDeviceInfo(
        systemIdentity: String = "host::"
    ) async throws -> ADBAndroidTVDeviceInfo {
        let connectedDevice = try await session.connect(systemIdentity: systemIdentity)
        let properties = try await readDeviceProperties()

        return ADBAndroidTVDeviceInfo(
            connectedDevice: connectedDevice,
            manufacturer: properties[.manufacturer, default: ""],
            model: properties[.model, default: ""],
            productName: properties[.productName, default: ""],
            deviceName: properties[.deviceName, default: ""],
            androidVersion: properties[.androidVersion, default: ""],
            sdkVersion: properties[.sdkVersion, default: ""],
            buildFingerprint: properties[.buildFingerprint, default: ""]
        )
    }

    public mutating func readDeviceProperties() async throws -> [ADBDeviceProperty: String] {
        var values: [ADBDeviceProperty: String] = [:]

        for property in ADBDeviceProperty.probeOrder {
            values[property] = try await readProperty(property)
        }

        return values
    }

    public mutating func readProperty(_ property: ADBDeviceProperty) async throws -> String {
        let invocation = try property.shellInvocation()
        let output = try await session.runShellCommand(invocation.shellCommand)
        return try invocation.validatedOutput(from: output).normalizedPropertyValue
    }
}

public struct ADBAndroidTVDeviceInfo: Equatable, Sendable {
    public var connectedDevice: ADBConnectedDevice
    public var manufacturer: String
    public var model: String
    public var productName: String
    public var deviceName: String
    public var androidVersion: String
    public var sdkVersion: String
    public var buildFingerprint: String

    public init(
        connectedDevice: ADBConnectedDevice,
        manufacturer: String,
        model: String,
        productName: String,
        deviceName: String,
        androidVersion: String,
        sdkVersion: String,
        buildFingerprint: String
    ) {
        self.connectedDevice = connectedDevice
        self.manufacturer = manufacturer
        self.model = model
        self.productName = productName
        self.deviceName = deviceName
        self.androidVersion = androidVersion
        self.sdkVersion = sdkVersion
        self.buildFingerprint = buildFingerprint
    }
}

public enum ADBDeviceProperty: String, CaseIterable, Sendable {
    case manufacturer = "ro.product.manufacturer"
    case model = "ro.product.model"
    case productName = "ro.product.name"
    case deviceName = "ro.product.device"
    case androidVersion = "ro.build.version.release"
    case sdkVersion = "ro.build.version.sdk"
    case buildFingerprint = "ro.build.fingerprint"

    public static let probeOrder: [ADBDeviceProperty] = [
        .manufacturer,
        .model,
        .productName,
        .deviceName,
        .androidVersion,
        .sdkVersion,
        .buildFingerprint
    ]

    public func shellCommand() throws -> ADBShellCommand {
        try ADBShellCommand("getprop \(rawValue)")
    }

    public func shellInvocation() throws -> ADBCheckedShellInvocation {
        try ADBCheckedShellInvocation(command: shellCommand())
    }
}

private extension ADBShellOutput {
    var normalizedPropertyValue: String {
        utf8String.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
