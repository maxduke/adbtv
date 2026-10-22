import ADBClientCore
import Foundation

extension ADBSharedStoragePath {
    var adbTVDisplayName: String { isRoot ? adbTVLocalized("Shared Storage") : name }
}

enum ADBTVFileSortOrder: String, CaseIterable, Identifiable {
    case name
    case newest
    case largest

    var id: Self { self }

    var title: String {
        switch self {
        case .name: return adbTVLocalized("Name")
        case .newest: return adbTVLocalized("Newest First")
        case .largest: return adbTVLocalized("Largest First")
        }
    }
}

struct ADBTVFileBrowserQuery {
    var searchText = ""
    var sortOrder = ADBTVFileSortOrder.name

    func apply(to items: [ADBSharedStorageItem], locale: Locale = .current) -> [ADBSharedStorageItem] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter {
            matches($0.name, search: search, locale: locale)
        }.sorted { lhs, rhs in
            let leftIsDirectory = lhs.kind == .directory
            let rightIsDirectory = rhs.kind == .directory
            if leftIsDirectory != rightIsDirectory { return leftIsDirectory }
            switch sortOrder {
            case .newest where lhs.entry.modificationTime != rhs.entry.modificationTime:
                return lhs.entry.modificationTime > rhs.entry.modificationTime
            case .largest where !leftIsDirectory && lhs.byteCount != rhs.byteCount:
                return lhs.byteCount > rhs.byteCount
            default:
                break
            }
            let comparison = lhs.name.compare(
                rhs.name,
                options: [.numeric, .caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    func emptyState(items: [ADBSharedStorageItem], status: ADBTVFileListStatus) -> ADBTVFileEmptyState? {
        guard status == .ready else { return nil }
        if items.isEmpty { return .emptyFolder }
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.contains { matches($0.name, search: search, locale: .current) } ? nil : .noMatches
    }

    private func matches(_ name: String, search: String, locale: Locale) -> Bool {
        search.isEmpty || name.range(
            of: search,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: locale
        ) != nil
    }
}

enum ADBTVFileEmptyState: Equatable {
    case emptyFolder
    case noMatches
}

struct ADBTVFileBrowserFailure: Equatable {
    var userMessage: String
    var diagnosticDetail: DiagnosticDetail
}

enum ADBTVFileListStatus: Equatable {
    case idle
    case loading
    case ready
    case failed(ADBTVFileBrowserFailure)

    mutating func finishCancelledLoad() {
        guard self == .loading else { return }
        self = .ready
    }
}
