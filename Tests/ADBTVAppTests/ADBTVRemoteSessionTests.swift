import XCTest
@testable import ADBTVApp

final class ADBTVRemoteSessionTests: XCTestCase {
    func testOrdersActionsAndRejectsNewestWhenBufferIsFull() async throws {
        let gate = TestGate()
        let channel = TestRemoteChannel(gate: gate)
        let events = RemoteEventRecorder()
        let session = ADBTVRemoteSession(
            channelFactory: { channel },
            eventHandler: { await events.record($0) }
        )

        await session.start()
        var result = await session.enqueue(.up)
        XCTAssertEqual(result, .accepted)
        try await waitUntil { await channel.actions().count == 1 }

        result = await session.enqueue(.volumeUp, policy: .onlyWhenIdle)
        XCTAssertEqual(result, .busy)

        for action in [
            ADBTVRemoteAction.left, .right, .down, .select, .back, .home, .menu, .settings
        ] {
            result = await session.enqueue(action)
            XCTAssertEqual(result, .accepted)
        }
        result = await session.enqueue(.power)
        XCTAssertEqual(result, .full)

        await gate.open()
        try await waitUntil { await events.contains(.drained) }
        let recordedActions = await channel.actions()
        XCTAssertEqual(
            recordedActions,
            [.up, .left, .right, .down, .select, .back, .home, .menu, .settings]
        )
        await session.close()
    }

    func testFailedActionIsNotReplayedAndReconnectsOnce() async throws {
        let failedChannel = TestRemoteChannel(error: TestError.failed)
        let replacementChannel = TestRemoteChannel()
        let factory = TestRemoteChannelFactory(channels: [failedChannel, replacementChannel])
        let events = RemoteEventRecorder()
        let session = ADBTVRemoteSession(
            channelFactory: { try await factory.makeChannel() },
            eventHandler: { await events.record($0) }
        )

        await session.start()
        var result = await session.enqueue(.home)
        XCTAssertEqual(result, .accepted)
        try await waitUntil {
            let callCount = await factory.callCount()
            let isReady = await events.contains(.ready, count: 2)
            return callCount == 2 && isReady
        }

        let failedActions = await failedChannel.actions()
        let replacementActions = await replacementChannel.actions()
        let containsFailure = await events.containsActionFailure(for: .home)
        let containsReconnect = await events.contains(.reconnecting)
        XCTAssertEqual(failedActions, [.home])
        XCTAssertEqual(replacementActions, [])
        XCTAssertTrue(containsFailure)
        XCTAssertTrue(containsReconnect)

        result = await session.enqueue(.settings)
        XCTAssertEqual(result, .accepted)
        try await waitUntil { await replacementChannel.actions() == [.settings] }
        await session.close()
    }

    private func waitUntil(
        timeoutIterations: Int = 500,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for asynchronous condition")
        throw TestError.timedOut
    }
}

private enum TestError: Error, Sendable {
    case failed
    case noChannel
    case timedOut
}

private actor TestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private actor TestRemoteChannel: ADBTVRemoteSessionChannel {
    private let gate: TestGate?
    private let error: Error?
    private var recordedActions: [ADBTVRemoteAction] = []

    init(gate: TestGate? = nil, error: Error? = nil) {
        self.gate = gate
        self.error = error
    }

    func send(_ action: ADBTVRemoteAction) async throws {
        recordedActions.append(action)
        if let gate {
            await gate.wait()
        }
        if let error {
            throw error
        }
    }

    func cancel() async {}

    func actions() -> [ADBTVRemoteAction] {
        recordedActions
    }
}

private actor TestRemoteChannelFactory {
    private var channels: [TestRemoteChannel]
    private var calls = 0

    init(channels: [TestRemoteChannel]) {
        self.channels = channels
    }

    func makeChannel() throws -> any ADBTVRemoteSessionChannel {
        calls += 1
        guard !channels.isEmpty else {
            throw TestError.noChannel
        }
        return channels.removeFirst()
    }

    func callCount() -> Int {
        calls
    }
}

private actor RemoteEventRecorder {
    private var events: [ADBTVRemoteSessionEvent] = []

    func record(_ event: ADBTVRemoteSessionEvent) {
        events.append(event)
    }

    func contains(_ event: ADBTVRemoteSessionEvent, count: Int = 1) -> Bool {
        events.filter { $0 == event }.count >= count
    }

    func containsActionFailure(for action: ADBTVRemoteAction) -> Bool {
        events.contains {
            guard case .actionFailed(let failure) = $0 else {
                return false
            }
            return failure.action == action
        }
    }
}
