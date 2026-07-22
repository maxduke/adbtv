import ADBClientCore
import Foundation

protocol ADBTVRemoteSessionChannel: Sendable {
    func send(_ action: ADBTVRemoteAction) async throws
    func cancel() async
}

struct ADBTVRemoteSessionFailure: Equatable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case initialConnection
        case action
        case reconnect
    }

    let stage: Stage
    let action: ADBTVRemoteAction?
    let summary: String
    let timedOut: Bool
}

enum ADBTVRemoteSessionEvent: Equatable, Sendable {
    case connecting
    case ready
    case sending(ADBTVRemoteAction)
    case sent(ADBTVRemoteAction)
    case drained
    case connectionFailed(ADBTVRemoteSessionFailure)
    case actionFailed(ADBTVRemoteSessionFailure)
    case reconnecting
    case reconnectFailed(
        actionFailure: ADBTVRemoteSessionFailure,
        connectionFailure: ADBTVRemoteSessionFailure
    )
    case closed
}

actor ADBTVRemoteSession {
    typealias ChannelFactory = @Sendable () async throws -> any ADBTVRemoteSessionChannel
    typealias EventHandler = @Sendable (ADBTVRemoteSessionEvent) async -> Void

    enum EnqueuePolicy: Sendable {
        case ordered
        case onlyWhenIdle
    }

    enum EnqueueResult: Equatable, Sendable {
        case accepted
        case busy
        case full
        case unavailable
    }

    private enum State: Equatable {
        case idle
        case connecting
        case ready
        case reconnecting
        case failed
        case closed
    }

    private let maximumPendingActionCount: Int
    private let actionTimeout: ADBTVOperationTimeout
    private let channelFactory: ChannelFactory
    private let eventHandler: EventHandler

    private var state = State.idle
    private var generation = 0
    private var channel: (any ADBTVRemoteSessionChannel)?
    private var pendingActions: [ADBTVRemoteAction] = []
    private var isSending = false
    private var processor: Task<Void, Never>?

    init(
        maximumPendingActionCount: Int = 8,
        actionTimeout: ADBTVOperationTimeout = ADBTVOperationTimeoutPolicy.remoteAction,
        channelFactory: @escaping ChannelFactory,
        eventHandler: @escaping EventHandler
    ) {
        precondition(maximumPendingActionCount > 0)
        self.maximumPendingActionCount = maximumPendingActionCount
        self.actionTimeout = actionTimeout
        self.channelFactory = channelFactory
        self.eventHandler = eventHandler
    }

    func start() async {
        guard state == .idle else {
            return
        }
        generation += 1
        let currentGeneration = generation
        state = .connecting
        await eventHandler(.connecting)
        await connect(generation: currentGeneration, stage: .initialConnection)
    }

    func retryConnection() async {
        guard state == .failed else {
            return
        }
        generation += 1
        let currentGeneration = generation
        state = .connecting
        await eventHandler(.connecting)
        await connect(generation: currentGeneration, stage: .initialConnection)
    }

    func enqueue(
        _ action: ADBTVRemoteAction,
        policy: EnqueuePolicy = .ordered
    ) -> EnqueueResult {
        guard state == .ready, channel != nil else {
            return .unavailable
        }

        switch policy {
        case .ordered:
            guard pendingActions.count < maximumPendingActionCount else {
                return .full
            }
        case .onlyWhenIdle:
            guard !isSending, pendingActions.isEmpty, processor == nil else {
                return .busy
            }
        }

        pendingActions.append(action)
        scheduleProcessingIfNeeded()
        return .accepted
    }

    func close() async {
        guard state != .closed else {
            return
        }
        generation += 1
        state = .closed
        pendingActions.removeAll(keepingCapacity: false)
        processor?.cancel()
        processor = nil
        isSending = false
        let channel = self.channel
        self.channel = nil
        await channel?.cancel()
        await eventHandler(.closed)
    }

    private func connect(
        generation currentGeneration: Int,
        stage: ADBTVRemoteSessionFailure.Stage
    ) async {
        do {
            let channel = try await channelFactory()
            guard generation == currentGeneration,
                  state == .connecting || state == .reconnecting,
                  !Task.isCancelled else {
                await channel.cancel()
                return
            }
            self.channel = channel
            state = .ready
            await eventHandler(.ready)
        } catch is CancellationError {
            return
        } catch {
            guard generation == currentGeneration, state != .closed else {
                return
            }
            state = .failed
            await eventHandler(.connectionFailed(failure(
                stage: stage,
                action: nil,
                error: error
            )))
        }
    }

    private func scheduleProcessingIfNeeded() {
        guard processor == nil, state == .ready, !pendingActions.isEmpty else {
            return
        }
        let currentGeneration = generation
        processor = Task { [weak self] in
            await self?.processActions(generation: currentGeneration)
        }
    }

    private func processActions(generation currentGeneration: Int) async {
        while generation == currentGeneration,
              state == .ready,
              !Task.isCancelled,
              !pendingActions.isEmpty,
              let channel {
            let action = pendingActions.removeFirst()
            isSending = true
            await eventHandler(.sending(action))

            do {
                try await actionTimeout.run(operation: .remoteAction) {
                    try await channel.send(action)
                }
            } catch is CancellationError {
                isSending = false
                guard state != .closed else {
                    return
                }
                await handleActionFailure(
                    action: action,
                    error: CancellationError(),
                    generation: currentGeneration
                )
                return
            } catch {
                isSending = false
                guard state != .closed else {
                    return
                }
                await handleActionFailure(
                    action: action,
                    error: error,
                    generation: currentGeneration
                )
                return
            }

            guard generation == currentGeneration, state == .ready else {
                return
            }
            isSending = false
            await eventHandler(.sent(action))
        }

        guard generation == currentGeneration, state == .ready else {
            return
        }
        processor = nil
        await eventHandler(.drained)
        if !pendingActions.isEmpty {
            scheduleProcessingIfNeeded()
        }
    }

    private func handleActionFailure(
        action: ADBTVRemoteAction,
        error: Error,
        generation currentGeneration: Int
    ) async {
        let actionFailure = failure(stage: .action, action: action, error: error)
        pendingActions.removeAll(keepingCapacity: false)
        processor = nil
        let failedChannel = channel
        channel = nil
        await failedChannel?.cancel()
        await eventHandler(.actionFailed(actionFailure))

        guard generation == currentGeneration, state != .closed else {
            return
        }
        state = .reconnecting
        await eventHandler(.reconnecting)

        do {
            let channel = try await channelFactory()
            guard generation == currentGeneration,
                  state == .reconnecting,
                  !Task.isCancelled else {
                await channel.cancel()
                return
            }
            self.channel = channel
            state = .ready
            await eventHandler(.ready)
        } catch is CancellationError {
            return
        } catch {
            guard generation == currentGeneration, state != .closed else {
                return
            }
            state = .failed
            await eventHandler(.reconnectFailed(
                actionFailure: actionFailure,
                connectionFailure: failure(
                    stage: .reconnect,
                    action: nil,
                    error: error
                )
            ))
        }
    }

    private func failure(
        stage: ADBTVRemoteSessionFailure.Stage,
        action: ADBTVRemoteAction?,
        error: Error
    ) -> ADBTVRemoteSessionFailure {
        ADBTVRemoteSessionFailure(
            stage: stage,
            action: action,
            summary: String(describing: error),
            timedOut: error is ADBTVOperationTimeoutError
        )
    }
}
