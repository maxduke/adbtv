import Foundation

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

    public mutating func runService(
        _ service: String,
        maximumOutputByteCount: Int
    ) async throws -> ADBServiceOutput {
        guard !service.isEmpty else {
            throw ADBDeviceSessionError.emptyService
        }
        guard !service.utf8.contains(0) else {
            throw ADBDeviceSessionError.serviceContainsNullByte
        }
        guard maximumOutputByteCount > 0 else {
            throw ADBDeviceSessionError.invalidMaximumOutputByteCount(maximumOutputByteCount)
        }

        let startOutput = try await transportSession.startService(service)
        let localID = try startOutput.startedStreamLocalID(service: "rawService")
        var isReady = false
        var bytes: [UInt8] = []

        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeServiceFinished
            }

            for event in output.events {
                switch event {
                case .streamReady(let eventLocalID, _) where eventLocalID == localID:
                    isReady = true

                case .streamData(let eventLocalID, _, let payload) where eventLocalID == localID:
                    guard isReady else {
                        throw ADBDeviceSessionError.serviceDataBeforeReady(localID: localID)
                    }
                    guard payload.count <= maximumOutputByteCount - bytes.count else {
                        throw ADBDeviceSessionError.serviceOutputTooLarge(
                            maximumByteCount: maximumOutputByteCount
                        )
                    }
                    bytes.append(contentsOf: payload)

                case .streamClosed(let eventLocalID, _) where eventLocalID == localID:
                    guard isReady else {
                        throw ADBDeviceSessionError.streamClosedBeforeReady(localID: localID)
                    }
                    return ADBServiceOutput(bytes: bytes)

                default:
                    continue
                }
            }
        }
    }

    public mutating func pushFile(
        contents: [UInt8],
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler = { _ in }
    ) async throws -> [ADBSyncPushEvent] {
        let startOutput = try await transportSession.startService("sync:")
        let localID = try startOutput.startedStreamLocalID(service: "sync:")
        try await waitForStreamReady(localID: localID, service: "sync:")

        var events: [ADBSyncPushEvent] = []
        let maxPayloadByteCount = try streamWritePayloadByteCount()
        var batcher = try ADBSyncPushBatcher(
            plan: plan,
            contents: contents,
            maxByteCount: maxPayloadByteCount
        )
        var responseDecoder = ADBSyncResponseDecoder()
        var bufferedResponse: ADBSyncResponse?

        while let batch = try batcher.next() {
            _ = try await transportSession.writeStream(localID: localID, payload: batch.payload)
            let outputs = try await waitForStreamWritable(localID: localID)
            for output in outputs where bufferedResponse == nil {
                bufferedResponse = try syncResponse(
                    in: output,
                    localID: localID,
                    decoder: &responseDecoder
                )
            }
            for event in batch.completedEvents {
                events.append(event)
                await eventHandler(event)
            }
            if case .fail? = bufferedResponse {
                break
            }
        }

        let response: ADBSyncResponse
        if let bufferedResponse {
            response = bufferedResponse
        } else {
            response = try await waitForSyncResponse(localID: localID, decoder: &responseDecoder)
        }
        let responseEvent = ADBSyncPushEvent.responseEvent(response)
        events.append(responseEvent)
        await eventHandler(responseEvent)

        try await finishSyncStreamIfOpen(localID: localID)
        return events
    }

    public mutating func listDirectory(
        _ path: ADBRemotePath
    ) async throws -> [ADBSyncDirectoryEntry] {
        let startOutput = try await transportSession.startService("sync:")
        let localID = try startOutput.startedStreamLocalID(service: "sync:")
        try await waitForStreamReady(localID: localID, service: "sync:")

        do {
            let request = try ADBSyncFrame.listV1(path: path).encoded()
            _ = try await transportSession.writeStream(localID: localID, payload: request)
            var outputs = try await waitForStreamWritable(localID: localID)
            var decoder = ADBSyncDirectoryResponseDecoder()
            var entries: [ADBSyncDirectoryEntry] = []
            var isDone = false

            while !isDone {
                try Task.checkCancellation()
                for output in outputs {
                    for payload in syncPayloads(in: output, localID: localID) {
                        for response in try decoder.append(payload) {
                            switch response {
                            case .entry(let entry) where entry.name != "." && entry.name != "..":
                                entries.append(entry)
                            case .entry:
                                continue
                            case .done:
                                isDone = true
                            case .fail(let message):
                                throw ADBSyncTransferError.remoteFailure(message)
                            }
                        }
                    }
                }

                guard !isDone else {
                    break
                }
                guard let output = try await transportSession.receiveNext() else {
                    throw ADBDeviceSessionError.transportClosedBeforeSyncCompletion(localID: localID)
                }
                if output.containsEvent(where: { $0.localStreamID == localID && $0.isStreamClosed }) {
                    throw ADBDeviceSessionError.streamClosedBeforeSyncCompletion(localID: localID)
                }
                outputs = [output]
            }

            try await finishSyncStreamIfOpen(localID: localID)
            return entries
        } catch {
            try? await finishSyncStreamIfOpen(localID: localID)
            throw error
        }
    }

    public mutating func pullFile(
        _ remotePath: ADBRemotePath,
        to localURL: URL,
        expectedByteCount: Int64? = nil,
        eventHandler: @escaping ADBSyncPullEventHandler = { _ in }
    ) async throws -> Int64 {
        try? FileManager.default.removeItem(at: localURL)
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw ADBSyncTransferError.couldNotCreateLocalFile
        }

        let fileHandle = try FileHandle(forWritingTo: localURL)
        var completed = false
        defer {
            try? fileHandle.close()
            if !completed {
                try? FileManager.default.removeItem(at: localURL)
            }
        }

        let startOutput = try await transportSession.startService("sync:")
        let localID = try startOutput.startedStreamLocalID(service: "sync:")
        try await waitForStreamReady(localID: localID, service: "sync:")
        await eventHandler(.started(remotePath: remotePath, totalByteCount: expectedByteCount))

        do {
            let request = try ADBSyncFrame.receiveV1(path: remotePath).encoded()
            _ = try await transportSession.writeStream(localID: localID, payload: request)
            var outputs = try await waitForStreamWritable(localID: localID)
            var decoder = ADBSyncPullResponseDecoder()
            var receivedByteCount: Int64 = 0
            var isDone = false

            while !isDone {
                try Task.checkCancellation()
                for output in outputs {
                    for payload in syncPayloads(in: output, localID: localID) {
                        for response in try decoder.append(payload) {
                            switch response {
                            case .data(let bytes):
                                try fileHandle.write(contentsOf: Data(bytes))
                                receivedByteCount += Int64(bytes.count)
                                await eventHandler(.progress(
                                    receivedByteCount: receivedByteCount,
                                    totalByteCount: expectedByteCount
                                ))
                            case .done:
                                isDone = true
                            case .fail(let message):
                                throw ADBSyncTransferError.remoteFailure(message)
                            }
                        }
                    }
                }

                guard !isDone else {
                    break
                }
                guard let output = try await transportSession.receiveNext() else {
                    throw ADBDeviceSessionError.transportClosedBeforeSyncCompletion(localID: localID)
                }
                if output.containsEvent(where: { $0.localStreamID == localID && $0.isStreamClosed }) {
                    throw ADBDeviceSessionError.streamClosedBeforeSyncCompletion(localID: localID)
                }
                outputs = [output]
            }

            try fileHandle.close()
            try await finishSyncStreamIfOpen(localID: localID)
            completed = true
            await eventHandler(.completed(receivedByteCount: receivedByteCount))
            return receivedByteCount
        } catch {
            try? await finishSyncStreamIfOpen(localID: localID)
            throw error
        }
    }

    public mutating func pushFile(
        from localURL: URL,
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler = { _ in }
    ) async throws -> [ADBSyncPushEvent] {
        guard let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw ADBSyncTransferError.localFileSizeUnavailable
        }
        let expectedTotal = plan.totalByteCount ?? fileSize
        guard expectedTotal == fileSize else {
            throw ADBSyncTransferError.localFileSizeMismatch(expected: expectedTotal, actual: fileSize)
        }

        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        let startOutput = try await transportSession.startService("sync:")
        let localID = try startOutput.startedStreamLocalID(service: "sync:")
        try await waitForStreamReady(localID: localID, service: "sync:")

        do {
            let maxPayloadByteCount = try streamWritePayloadByteCount()
            var pendingBytes = try ADBSyncFrame.sendV1(
                path: plan.remotePath,
                mode: plan.mode
            ).encoded()
            var sentByteCount = 0
            var reportedByteCount = 0
            var responseDecoder = ADBSyncResponseDecoder()
            var bufferedResponse: ADBSyncResponse?
            var events: [ADBSyncPushEvent] = [
                .started(remotePath: plan.remotePath, totalByteCount: expectedTotal)
            ]
            await eventHandler(events[0])

            while let data = try fileHandle.read(upToCount: ADBSyncFrame.maxDataByteCount), !data.isEmpty {
                try Task.checkCancellation()
                let frameBytes = try ADBSyncFrame.data(Array(data)).encoded()
                if !pendingBytes.isEmpty,
                   pendingBytes.count + frameBytes.count > maxPayloadByteCount {
                    let outputs = try await writeSyncBytes(pendingBytes, localID: localID)
                    if bufferedResponse == nil {
                        bufferedResponse = try firstSyncResponse(
                            in: outputs,
                            localID: localID,
                            decoder: &responseDecoder
                        )
                    }
                    if case .fail(let message)? = bufferedResponse {
                        throw ADBSyncTransferError.remoteFailure(message)
                    }
                    pendingBytes.removeAll(keepingCapacity: true)
                    if sentByteCount > reportedByteCount {
                        let progress = ADBSyncPushEvent.progress(
                            sentByteCount: sentByteCount,
                            totalByteCount: expectedTotal
                        )
                        events.append(progress)
                        await eventHandler(progress)
                        reportedByteCount = sentByteCount
                    }
                }
                pendingBytes.append(contentsOf: frameBytes)
                sentByteCount += data.count
            }

            pendingBytes.append(contentsOf: try ADBSyncFrame.done(
                modificationTime: plan.modificationTime
            ).encoded())
            let outputs = try await writeSyncBytes(pendingBytes, localID: localID)
            if bufferedResponse == nil {
                bufferedResponse = try firstSyncResponse(
                    in: outputs,
                    localID: localID,
                    decoder: &responseDecoder
                )
            }
            if sentByteCount > reportedByteCount {
                let progress = ADBSyncPushEvent.progress(
                    sentByteCount: sentByteCount,
                    totalByteCount: expectedTotal
                )
                events.append(progress)
                await eventHandler(progress)
            }
            let finished = ADBSyncPushEvent.finishedSending(
                sentByteCount: sentByteCount,
                totalByteCount: expectedTotal
            )
            events.append(finished)
            await eventHandler(finished)

            let response: ADBSyncResponse
            if let bufferedResponse {
                response = bufferedResponse
            } else {
                response = try await waitForSyncResponse(
                    localID: localID,
                    decoder: &responseDecoder
                )
            }
            let responseEvent = ADBSyncPushEvent.responseEvent(response)
            events.append(responseEvent)
            await eventHandler(responseEvent)
            try await finishSyncStreamIfOpen(localID: localID)

            if case .fail(let message) = response {
                throw ADBSyncTransferError.remoteFailure(message)
            }
            return events
        } catch {
            try? await finishSyncStreamIfOpen(localID: localID)
            throw error
        }
    }

    public mutating func receiveNext() async throws -> ADBTransportSessionOutput? {
        try await transportSession.receiveNext()
    }

    private func streamWritePayloadByteCount() throws -> Int {
        let maxData = transportSession.driver.client.connection.phase.maxData ?? ADBConnectionState.defaultMaxData
        guard maxData > 0 else {
            throw ADBDeviceSessionError.invalidMaxData(maxData)
        }

        return min(Int(maxData), ADBSyncPushBatcher.maximumBatchByteCount)
    }

    private mutating func writeSyncBytes(
        _ bytes: [UInt8],
        localID: UInt32
    ) async throws -> [ADBTransportSessionOutput] {
        let maximumByteCount = try streamWritePayloadByteCount()
        var outputs: [ADBTransportSessionOutput] = []
        var offset = 0

        while offset < bytes.count {
            let endOffset = min(offset + maximumByteCount, bytes.count)
            _ = try await transportSession.writeStream(
                localID: localID,
                payload: Array(bytes[offset ..< endOffset])
            )
            outputs.append(contentsOf: try await waitForStreamWritable(localID: localID))
            offset = endOffset
        }
        return outputs
    }

    private func firstSyncResponse(
        in outputs: [ADBTransportSessionOutput],
        localID: UInt32,
        decoder: inout ADBSyncResponseDecoder
    ) throws -> ADBSyncResponse? {
        for output in outputs {
            for payload in syncPayloads(in: output, localID: localID) {
                if let response = try decoder.append(payload).first {
                    return response
                }
            }
        }
        return nil
    }

    private func syncPayloads(
        in output: ADBTransportSessionOutput,
        localID: UInt32
    ) -> [[UInt8]] {
        output.events.compactMap { event in
            guard case .streamData(let eventLocalID, _, let payload) = event,
                  eventLocalID == localID else {
                return nil
            }
            return payload
        }
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

    private mutating func waitForStreamWritable(
        localID: UInt32
    ) async throws -> [ADBTransportSessionOutput] {
        var outputs: [ADBTransportSessionOutput] = []

        while true {
            guard let output = try await transportSession.receiveNext() else {
                throw ADBDeviceSessionError.transportClosedBeforeStreamWritable(localID: localID)
            }
            outputs.append(output)

            if output.containsEvent(where: { event in
                event.localStreamID == localID && event.isStreamWritable
            }) {
                return outputs
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

            if let response = try syncResponse(in: output, localID: localID, decoder: &decoder) {
                return response
            }

            for event in output.events {
                if event.localStreamID == localID && event.isStreamClosed {
                    throw ADBDeviceSessionError.streamClosedBeforeSyncResponse(localID: localID)
                }
            }
        }
    }

    private mutating func finishSyncStreamIfOpen(localID: UInt32) async throws {
        guard transportSession.driver.client.connection.stream(localID: localID) != nil else {
            return
        }

        _ = try await transportSession.writeStream(localID: localID, payload: try ADBSyncFrame.quit().encoded())
        do {
            _ = try await waitForStreamWritable(localID: localID)
        } catch let error as ADBDeviceSessionError {
            guard case .streamClosedBeforeWritable = error else {
                throw error
            }
            return
        }

        guard transportSession.driver.client.connection.stream(localID: localID) != nil else {
            return
        }
        _ = try await transportSession.closeStream(localID: localID)
    }

    private func syncResponse(
        in output: ADBTransportSessionOutput,
        localID: UInt32,
        decoder: inout ADBSyncResponseDecoder
    ) throws -> ADBSyncResponse? {
        for event in output.events {
            if case .streamData(let eventLocalID, _, let payload) = event, eventLocalID == localID,
               let response = try decoder.append(payload).first {
                return response
            }
        }

        return nil
    }
}

private struct ADBSyncWriteBatch: Sendable {
    var payload: [UInt8]
    var completedEvents: [ADBSyncPushEvent]
}

private struct ADBSyncPushBatcher: Sendable {
    static let maximumBatchByteCount = 1024 * 1024

    private enum Stage: Sendable {
        case send
        case data(offset: Int)
        case done
        case finished
    }

    private let plan: ADBSyncPushPlan
    private let contents: [UInt8]
    private let maxByteCount: Int
    private var stage: Stage
    private var currentFrameBytes: [UInt8]?
    private var currentFrameOffset: Int
    private var currentEvent: ADBSyncPushEvent?

    init(plan: ADBSyncPushPlan, contents: [UInt8], maxByteCount: Int) throws {
        let expectedTotal = plan.totalByteCount ?? contents.count
        guard expectedTotal == contents.count else {
            throw ADBSyncPushPlanError.totalByteCountMismatch(
                expected: expectedTotal,
                actual: contents.count
            )
        }

        self.plan = plan
        self.contents = contents
        self.maxByteCount = maxByteCount
        self.stage = .send
        self.currentFrameBytes = nil
        self.currentFrameOffset = 0
        self.currentEvent = nil
    }

    mutating func next() throws -> ADBSyncWriteBatch? {
        var payload: [UInt8] = []
        payload.reserveCapacity(maxByteCount)
        var completedEvents: [ADBSyncPushEvent] = []

        while payload.count < maxByteCount {
            if currentFrameBytes == nil {
                try loadNextFrame()
            }
            guard let currentFrameBytes else {
                break
            }

            let availableByteCount = maxByteCount - payload.count
            let remainingFrameByteCount = currentFrameBytes.count - currentFrameOffset
            let copiedByteCount = min(availableByteCount, remainingFrameByteCount)
            let endOffset = currentFrameOffset + copiedByteCount
            payload.append(contentsOf: currentFrameBytes[currentFrameOffset ..< endOffset])
            currentFrameOffset = endOffset

            if currentFrameOffset == currentFrameBytes.count {
                if let currentEvent {
                    completedEvents.append(currentEvent)
                }
                self.currentFrameBytes = nil
                currentFrameOffset = 0
                currentEvent = nil
            }
        }

        guard !payload.isEmpty else {
            return nil
        }
        return ADBSyncWriteBatch(payload: payload, completedEvents: completedEvents)
    }

    private mutating func loadNextFrame() throws {
        let frame: ADBSyncFrame
        switch stage {
        case .send:
            frame = try .sendV1(path: plan.remotePath, mode: plan.mode)
            currentEvent = .started(
                remotePath: plan.remotePath,
                totalByteCount: contents.count
            )
            stage = contents.isEmpty ? .done : .data(offset: 0)
        case .data(let offset):
            let endOffset = min(offset + ADBSyncFrame.maxDataByteCount, contents.count)
            frame = try .data(Array(contents[offset ..< endOffset]))
            currentEvent = .progress(
                sentByteCount: endOffset,
                totalByteCount: contents.count
            )
            stage = endOffset == contents.count ? .done : .data(offset: endOffset)
        case .done:
            frame = .done(modificationTime: plan.modificationTime)
            currentEvent = .finishedSending(
                sentByteCount: contents.count,
                totalByteCount: contents.count
            )
            stage = .finished
        case .finished:
            return
        }

        currentFrameBytes = try frame.encoded()
        currentFrameOffset = 0
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

public struct ADBServiceOutput: Equatable, Sendable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var utf8String: String {
        String(decoding: bytes, as: UTF8.self)
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
    case transportClosedBeforeSyncCompletion(localID: UInt32)
    case streamClosedBeforeSyncCompletion(localID: UInt32)
    case emptyService
    case serviceContainsNullByte
    case invalidMaximumOutputByteCount(Int)
    case transportClosedBeforeServiceFinished
    case serviceDataBeforeReady(localID: UInt32)
    case serviceOutputTooLarge(maximumByteCount: Int)
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
