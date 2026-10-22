import Foundation

public struct ADBSharedStoragePath: Equatable, Hashable, Sendable {
    public static let root = ADBSharedStoragePath(unchecked: ADBRemotePath.sharedStorageDirectory)

    public let remotePath: ADBRemotePath

    public init(_ remotePath: ADBRemotePath) throws {
        let rawValue = remotePath.rawValue
        guard rawValue == ADBRemotePath.sharedStorageDirectory.rawValue
                || rawValue.hasPrefix(ADBRemotePath.sharedStorageDirectory.rawValue + "/") else {
            throw ADBSharedStoragePathError.outsideSharedStorage
        }
        guard !rawValue.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ADBSharedStoragePathError.relativePathComponent
        }
        self.remotePath = remotePath
    }

    private init(unchecked remotePath: ADBRemotePath) {
        self.remotePath = remotePath
    }

    public var rawValue: String { remotePath.rawValue }
    public var isRoot: Bool { self == .root }
    public var name: String { isRoot ? "Shared Storage" : String(rawValue.split(separator: "/").last ?? "") }

    public var parent: Self? {
        guard !isRoot else {
            return nil
        }
        return try? Self(remotePath.parentDirectory)
    }

    public func appendingPathComponent(_ component: String) throws -> Self {
        try Self(remotePath.appendingPathComponent(component))
    }

    public func isDescendant(of other: Self) -> Bool {
        rawValue.hasPrefix(other.rawValue + "/")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}

public enum ADBSharedStoragePathError: Error, Equatable, Sendable {
    case outsideSharedStorage
    case relativePathComponent
}

public struct ADBSharedStorageItem: Equatable, Identifiable, Sendable {
    public var path: ADBSharedStoragePath
    public var entry: ADBSyncDirectoryEntry

    public init(path: ADBSharedStoragePath, entry: ADBSyncDirectoryEntry) {
        self.path = path
        self.entry = entry
    }

    public var id: String { path.rawValue }
    public var name: String { entry.name }
    public var kind: ADBSyncEntryKind { entry.mode.kind }
    public var byteCount: Int64 { Int64(entry.byteCount) }
    public var modificationTime: Date {
        Date(timeIntervalSince1970: TimeInterval(entry.modificationTime))
    }
}

public protocol ADBSharedStorageSession: ADBShellCommandRunningSession {
    mutating func listDirectory(_ path: ADBRemotePath) async throws -> [ADBSyncDirectoryEntry]
    mutating func pullFile(
        _ remotePath: ADBRemotePath,
        to localURL: URL,
        expectedByteCount: Int64?,
        eventHandler: @escaping ADBSyncPullEventHandler
    ) async throws -> Int64
    mutating func pushFile(
        from localURL: URL,
        plan: ADBSyncPushPlan,
        eventHandler: @escaping ADBSyncPushEventHandler
    ) async throws -> [ADBSyncPushEvent]
}

extension ADBDeviceSession: ADBSharedStorageSession {}

#if canImport(Network)
extension ADBDeviceConnection: ADBSharedStorageSession {}
#endif

public struct ADBSharedStorageManager<Session: ADBSharedStorageSession>: Sendable {
    public private(set) var session: Session

    public init(session: Session) {
        self.session = session
    }

    public mutating func contents(
        of directory: ADBSharedStoragePath
    ) async throws -> [ADBSharedStorageItem] {
        try await session.listDirectory(directory.remotePath)
            .map { entry in
                ADBSharedStorageItem(
                    path: try directory.appendingPathComponent(entry.name),
                    entry: entry
                )
            }
            .sortedForPresentation()
    }

    public mutating func upload(
        _ localURL: URL,
        to directory: ADBSharedStoragePath,
        replacingExisting: Bool = false,
        cleanup: (@Sendable (ADBSharedStoragePath) async -> String?)? = nil,
        eventHandler: @escaping ADBSyncPushEventHandler = { _ in }
    ) async throws -> ADBSharedStoragePath {
        let destination = try directory.appendingPathComponent(localURL.lastPathComponent)
        let temporary = try directory.appendingPathComponent(
            ".adbtv-upload-\(UUID().uuidString)"
        )
        let values = try localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = values.fileSize
        let modificationTime = values.contentModificationDate.map { date in
            UInt32(clamping: max(Int64(date.timeIntervalSince1970), 0))
        } ?? 0
        let plan = try ADBSyncPushPlan(
            remotePath: temporary.remotePath,
            modificationTime: modificationTime,
            totalByteCount: fileSize
        )
        do {
            _ = try await session.pushFile(
                from: localURL,
                plan: plan,
                eventHandler: eventHandler
            )
            try Task.checkCancellation()
            try await runChecked(Self.uploadCommitCommand(
                temporary: temporary.remotePath,
                destination: destination.remotePath,
                replacingExisting: replacingExisting
            ))
            return destination
        } catch {
            let cleanupError: String?
            if let cleanup {
                cleanupError = await cleanup(temporary)
            } else {
                do {
                    try await cleanupUpload(at: temporary)
                    cleanupError = nil
                } catch {
                    cleanupError = String(describing: error)
                }
            }
            if let cleanupError {
                throw ADBSharedStorageUploadCleanupError(
                    temporaryPath: temporary,
                    underlyingError: String(describing: error),
                    cleanupError: cleanupError
                )
            }
            throw error
        }
    }

    public mutating func cleanupUpload(at path: ADBSharedStoragePath) async throws {
        let value = path.remotePath.shellEscaped
        try await runChecked("rm -f \(value) && test ! -e \(value) && test ! -L \(value)")
    }

    static func uploadCommitCommand(
        temporary: ADBRemotePath,
        destination: ADBRemotePath,
        replacingExisting: Bool
    ) -> String {
        let source = temporary.shellEscaped
        let target = destination.shellEscaped
        let conflictCheck = replacingExisting
            ? ""
            : "elif [ -e \(target) ]; then printf 'Destination already exists\\n'; exit 1; "
        // Android 8's mv has no -T. Check type before moving and require a
        // regular file at the exact destination before reporting success.
        return "if [ -L \(target) ] || { [ -e \(target) ] && [ ! -f \(target) ]; }; then "
            + "printf 'Destination is not a regular file\\n'; exit 1; "
            + conflictCheck
            + "fi; mv \(replacingExisting ? "-f" : "-n") \(source) \(target) "
            + "&& test ! -e \(source) && test ! -L \(source) "
            + "&& test -f \(target) && test ! -L \(target)"
    }

    @discardableResult
    public mutating func download(
        _ item: ADBSharedStorageItem,
        to localURL: URL,
        eventHandler: @escaping ADBSyncPullEventHandler = { _ in }
    ) async throws -> Int64 {
        guard item.kind == .file else {
            throw ADBSharedStorageError.notARegularFile
        }
        return try await session.pullFile(
            item.path.remotePath,
            to: localURL,
            expectedByteCount: item.byteCount,
            eventHandler: eventHandler
        )
    }

    public mutating func createDirectory(
        named name: String,
        in parent: ADBSharedStoragePath
    ) async throws -> ADBSharedStoragePath {
        let path = try parent.appendingPathComponent(name)
        try await runChecked("mkdir \(path.remotePath.shellEscaped)")
        return path
    }

    public mutating func rename(
        _ item: ADBSharedStorageItem,
        to name: String
    ) async throws -> ADBSharedStoragePath {
        guard let parent = item.path.parent else {
            throw ADBSharedStorageError.cannotModifyRoot
        }
        return try await move(item, to: parent, name: name)
    }

    public mutating func move(
        _ item: ADBSharedStorageItem,
        to directory: ADBSharedStoragePath,
        name: String? = nil
    ) async throws -> ADBSharedStoragePath {
        let destination = try directory.appendingPathComponent(name ?? item.name)
        guard destination != item.path else {
            return destination
        }
        if item.kind == .directory,
           (destination == item.path || destination.isDescendant(of: item.path)) {
            throw ADBSharedStorageError.destinationInsideSource
        }
        let sourceValue = item.path.remotePath.shellEscaped
        let destinationValue = destination.remotePath.shellEscaped
        try await runChecked(
            "if [ -e \(destinationValue) ] || [ -L \(destinationValue) ]; "
                + "then printf 'Destination already exists\\n'; false; "
                + "else mv \(sourceValue) \(destinationValue); fi"
        )
        return destination
    }

    public mutating func delete(_ item: ADBSharedStorageItem) async throws {
        guard !item.path.isRoot else {
            throw ADBSharedStorageError.cannotModifyRoot
        }
        try await runChecked("rm -rf \(item.path.remotePath.shellEscaped)")
    }

    private mutating func runChecked(_ rawCommand: String) async throws {
        let invocation = try ADBCheckedShellInvocation(command: ADBShellCommand(rawCommand))
        let output = try await session.runShellCommand(invocation.shellCommand)
        _ = try invocation.validatedOutput(from: output)
    }
}

public enum ADBSharedStorageError: Error, Equatable, Sendable {
    case cannotModifyRoot
    case destinationInsideSource
    case notARegularFile
}

public struct ADBSharedStorageUploadCleanupError: Error, Equatable, Sendable {
    public let temporaryPath: ADBSharedStoragePath
    public let underlyingError: String
    public let cleanupError: String

    public init(
        temporaryPath: ADBSharedStoragePath,
        underlyingError: String,
        cleanupError: String
    ) {
        self.temporaryPath = temporaryPath
        self.underlyingError = underlyingError
        self.cleanupError = cleanupError
    }
}

private extension Array where Element == ADBSharedStorageItem {
    func sortedForPresentation() -> Self {
        sorted { lhs, rhs in
            let lhsRank = lhs.kind == .directory ? 0 : 1
            let rhsRank = rhs.kind == .directory ? 0 : 1
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
