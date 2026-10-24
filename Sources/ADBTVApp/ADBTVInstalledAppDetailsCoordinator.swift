import ADBClientCore
import Foundation

enum ADBTVInstalledAppDetailsEvent: Sendable {
    case page([ADBTVInstalledPackage], [String: ADBTVInstalledAppDetails])
    case finished(ADBTVInstalledAppDetailsLoadResult)
    case failed(any Error)
}

// Own one detail request independently of the SwiftUI view. Cancelling or
// replacing it revokes publication before the underlying task is cancelled.
@MainActor
final class ADBTVInstalledAppDetailsCoordinator {
    typealias EventHandler = @MainActor @Sendable (ADBTVInstalledAppDetailsEvent) -> Void

    private var requestID: UUID?
    private var task: Task<Void, Never>?

    nonisolated init() {}

    deinit { task?.cancel() }

    @discardableResult
    func start(
        _ packages: [ADBTVInstalledPackage],
        userID: Int,
        loadPage: @escaping ADBTVInstalledAppDetailsOperation.PageLoader,
        onEvent: @escaping EventHandler
    ) -> Task<Void, Never> {
        cancel()
        let id = UUID()
        requestID = id
        let task = Task { [weak self] in
            let operation = ADBTVInstalledAppDetailsOperation(loadPage: loadPage)
            do {
                let result = try await operation.load(packages, userID: userID) { [weak self] page, details in
                    await self?.publish(.page(page, details), requestID: id, to: onEvent)
                }
                self?.complete(.finished(result), requestID: id, onEvent: onEvent)
            } catch {
                self?.complete(.failed(error), requestID: id, onEvent: onEvent)
            }
        }
        self.task = task
        return task
    }

    func cancel() {
        let task = self.task
        requestID = nil
        self.task = nil
        task?.cancel()
    }

    private func publish(_ event: ADBTVInstalledAppDetailsEvent, requestID: UUID, to handler: EventHandler) {
        guard self.requestID == requestID, !Task.isCancelled else { return }
        handler(event)
    }

    private func complete(_ event: ADBTVInstalledAppDetailsEvent, requestID: UUID, onEvent: EventHandler) {
        guard self.requestID == requestID else { return }
        self.requestID = nil
        task = nil
        guard !Task.isCancelled else { return }
        onEvent(event)
    }
}
