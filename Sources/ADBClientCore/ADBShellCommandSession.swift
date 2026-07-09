public struct ADBShellCommandSession: Sendable {
    public let command: ADBShellCommand
    public private(set) var phase: ADBShellCommandSessionPhase

    private var outputBuffer: ADBShellOutputBuffer?

    public init(command: ADBShellCommand) {
        self.command = command
        self.phase = .idle
        self.outputBuffer = nil
    }

    public mutating func start(using connection: inout ADBConnectionState) throws -> ADBPacket {
        guard phase == .idle else {
            throw ADBShellCommandSessionError.alreadyStarted
        }

        let packet = try connection.open(service: command.serviceName)
        let localID = packet.arg0
        outputBuffer = ADBShellOutputBuffer(localID: localID)
        phase = .opening(localID: localID)
        return packet
    }

    public mutating func receive(_ event: ADBConnectionEvent) throws -> ADBShellCommandSessionResult {
        switch phase {
        case .idle:
            throw ADBShellCommandSessionError.notStarted

        case .opening(let localID):
            switch event {
            case .streamReady(let eventLocalID, let remoteID):
                guard eventLocalID == localID else {
                    throw ADBShellCommandSessionError.mismatchedStream(
                        expectedLocalID: localID,
                        actualLocalID: eventLocalID
                    )
                }

                phase = .running(localID: eventLocalID, remoteID: remoteID)
                return .opened(localID: eventLocalID, remoteID: remoteID)

            case .streamClosed(let eventLocalID, _), .streamData(let eventLocalID, _, _):
                throw ADBShellCommandSessionError.unexpectedEvent(event, expectedLocalID: localID)

            case .connected, .streamWritable:
                return .ignored
            }

        case .running(let localID, _):
            guard var outputBuffer else {
                throw ADBShellCommandSessionError.missingOutputBuffer(localID: localID)
            }

            let output = try outputBuffer.receive(event)
            self.outputBuffer = outputBuffer

            if let output {
                phase = .finished(output)
                return .finished(output)
            }

            return .updated

        case .finished:
            throw ADBShellCommandSessionError.alreadyFinished
        }
    }
}

public enum ADBShellCommandSessionPhase: Equatable, Sendable {
    case idle
    case opening(localID: UInt32)
    case running(localID: UInt32, remoteID: UInt32)
    case finished(ADBShellOutput)
}

public enum ADBShellCommandSessionResult: Equatable, Sendable {
    case opened(localID: UInt32, remoteID: UInt32)
    case updated
    case finished(ADBShellOutput)
    case ignored

    public var isFinished: Bool {
        if case .finished = self {
            return true
        }

        return false
    }
}

public enum ADBShellCommandSessionError: Error, Equatable, Sendable {
    case notStarted
    case alreadyStarted
    case alreadyFinished
    case missingOutputBuffer(localID: UInt32)
    case mismatchedStream(expectedLocalID: UInt32, actualLocalID: UInt32)
    case unexpectedEvent(ADBConnectionEvent, expectedLocalID: UInt32)
}
