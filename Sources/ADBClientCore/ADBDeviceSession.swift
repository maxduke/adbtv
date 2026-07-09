public struct ADBDeviceSession: Sendable {
    public private(set) var transportSession: ADBTransportSession

    public init(transportSession: ADBTransportSession) {
        self.transportSession = transportSession
    }

    public init(driver: ADBClientDriver = ADBClientDriver(), transport: any ADBByteTransport) {
        self.transportSession = ADBTransportSession(driver: driver, transport: transport)
    }

    public init(authenticationIdentity: any ADBAuthenticationIdentity, transport: any ADBByteTransport) {
        self.init(
            driver: ADBClientDriver(authenticationIdentity: authenticationIdentity),
            transport: transport
        )
    }

    public var connectionPhase: ADBConnectionPhase {
        transportSession.driver.client.connection.phase
    }

    @discardableResult
    public mutating func connect(systemIdentity: String = "host::") async throws -> ADBConnectedDevice {
        _ = try await transportSession.connect(systemIdentity: systemIdentity)

        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeConnection
            }

            if let device = output.connectedDevice {
                return device
            }
        }
    }

    public mutating func runShellCommand(_ command: ADBShellCommand) async throws -> ADBShellOutput {
        _ = try await transportSession.startShellCommand(command)

        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeShellCommandFinished(command: command.rawValue)
            }

            if let shellOutput = output.finishedShellOutput {
                return shellOutput
            }
        }
    }

    public mutating func pushFile(contents: [UInt8], plan: ADBSyncPushPlan) async throws -> [ADBSyncPushEvent] {
        let startOutput = try await transportSession.startService("sync:")
        let localID = try startOutput.startedStreamLocalID(service: "sync:")
        try await waitForStreamReady(localID: localID, service: "sync:")

        let encoding = try plan.encode(contents: contents)
        var events = encoding.events
        let maxPayloadByteCount = try streamWritePayloadByteCount()

        for chunk in try encoding.encodedBytes().chunks(maxByteCount: maxPayloadByteCount) {
            _ = try await transportSession.writeStream(localID: localID, payload: chunk)
            try await waitForStreamWritable(localID: localID)
        }

        var responseDecoder = ADBSyncResponseDecoder()
        let response = try await waitForSyncResponse(localID: localID, decoder: &responseDecoder)
        events.append(.responseEvent(response))

        try await finishSyncStream(localID: localID)
        return events
    }

    public mutating func receiveNext() async throws -> ADBTransportSessionOutput? {
        try await transportSession.receiveNext()
    }

    private func streamWritePayloadByteCount() throws -> Int {
        let maxData = transportSession.driver.client.connection.phase.maxData ?? ADBConnectionState.defaultMaxData
        guard maxData > 0 else {
            throw ADBDeviceSessionError.invalidMaxData(maxData)
        }

        return Int(maxData)
    }

    private mutating func waitForStreamReady(localID: UInt32, service: String) async throws {
        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeStreamReady(service: service)
            }

            if output.containsEvent(where: { event in
                event.localStreamID == localID && event.isStreamReady
            }) {
                return
            }

            if output.containsEvent(where: { event in
                event.localStreamID == localID && event.isStreamClosed
            }) {
                throw ADBDeviceSessionError.streamClosedBeforeReady(localID: localID)
            }
        }
    }

    private mutating func waitForStreamWritable(localID: UInt32) async throws {
        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeStreamWritable(localID: localID)
            }

            if output.containsEvent(where: { event in
                event.localStreamID == localID && event.isStreamWritable
            }) {
                return
            }

            if output.containsEvent(where: { event in
                event.localStreamID == localID && event.isStreamClosed
            }) {
                throw ADBDeviceSessionError.streamClosedBeforeWritable(localID: localID)
            }
        }
    }

    private mutating func waitForSyncResponse(
        localID: UInt32,
        decoder: inout ADBSyncResponseDecoder
    ) async throws -> ADBSyncResponse {
        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeSyncResponse(localID: localID)
            }

            for event in output.events {
                if case .streamData(let eventLocalID, _, let payload) = event, eventLocalID == localID {
                    if let response = try decoder.append(payload).first {
                        return response
                    }
                }

                if event.localStreamID == localID && event.isStreamClosed {
                    throw ADBDeviceSessionError.streamClosedBeforeSyncResponse(localID: localID)
                }
            }
        }
    }

    private mutating func finishSyncStream(localID: UInt32) async throws {
        _ = try await transportSession.writeStream(localID: localID, payload: try ADBSyncFrame.quit().encoded())
        try await waitForStreamWritable(localID: localID)
        _ = try await transportSession.closeStream(localID: localID)
    }
}

public struct ADBConnectedDevice: Equatable, Sendable {
    public var protocolVersion: UInt32
    public var maxData: UInt32
    public var banner: String

    public init(protocolVersion: UInt32, maxData: UInt32, banner: String) {
        self.protocolVersion = protocolVersion
        self.maxData = maxData
        self.banner = banner
    }
}

public enum ADBDeviceSessionError: Error, Equatable, Sendable {
    case transportClosedBeforeConnection
    case transportClosedBeforeShellCommandFinished(command: String)
    case missingStartedStream(service: String)
    case invalidMaxData(UInt32)
    case transportClosedBeforeStreamReady(service: String)
    case streamClosedBeforeReady(localID: UInt32)
    case transportClosedBeforeStreamWritable(localID: UInt32)
    case streamClosedBeforeWritable(localID: UInt32)
    case transportClosedBeforeSyncResponse(localID: UInt32)
    case streamClosedBeforeSyncResponse(localID: UInt32)
}

public extension ADBTransportSessionOutput {
    var events: [ADBConnectionEvent] {
        driverOutput.actions.flatMap { $0.events }
    }

    var connectedDevice: ADBConnectedDevice? {
        for action in driverOutput.actions {
            for event in action.events {
                if case .connected(let protocolVersion, let maxData, let banner) = event {
                    return ADBConnectedDevice(
                        protocolVersion: protocolVersion,
                        maxData: maxData,
                        banner: banner
                    )
                }
            }
        }

        return nil
    }

    var finishedShellOutput: ADBShellOutput? {
        for action in driverOutput.actions {
            for shellResult in action.shellResults {
                if case .finished(let output) = shellResult {
                    return output
                }
            }
        }

        return nil
    }

    func startedStreamLocalID(service: String) throws -> UInt32 {
        guard let packet = driverOutput.packetsToSend.first(where: { $0.command == .open }) else {
            throw ADBDeviceSessionError.missingStartedStream(service: service)
        }

        return packet.arg0
    }

    func containsEvent(where predicate: (ADBConnectionEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }
}

private extension ADBConnectionEvent {
    var isStreamWritable: Bool {
        if case .streamWritable = self {
            return true
        }

        return false
    }

    var isStreamReady: Bool {
        if case .streamReady = self {
            return true
        }

        return false
    }

    var isStreamClosed: Bool {
        if case .streamClosed = self {
            return true
        }

        return false
    }
}

private extension Array where Element == UInt8 {
    func chunks(maxByteCount: Int) -> [[UInt8]] {
        guard !isEmpty else {
            return []
        }

        var result: [[UInt8]] = []
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maxByteCount, count)
            result.append(Array(self[offset..<end]))
            offset = end
        }

        return result
    }
}
