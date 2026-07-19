import ADBClientCore
import Foundation
import ZIPFoundation

public struct ADBTVPreparedAPKM: Equatable, Sendable {
    public let files: [ADBPackageSessionFile]
    public let temporaryDirectoryURL: URL

    public func removeTemporaryFiles() throws {
        try FileManager.default.removeItem(at: temporaryDirectoryURL)
    }
}

public struct ADBTVAPKMExtractor: Sendable {
    public static let defaultMaximumEntryCount = 64
    public static let defaultMaximumUncompressedByteCount = ADBTVInstallPackageLimits.maximumByteCount
    public static let maximumEntryPathByteCount = 1024

    public let maximumEntryCount: Int
    public let maximumUncompressedByteCount: Int64

    public init(
        maximumEntryCount: Int = Self.defaultMaximumEntryCount,
        maximumUncompressedByteCount: Int64 = Self.defaultMaximumUncompressedByteCount
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumUncompressedByteCount = maximumUncompressedByteCount
    }

    public func extract(from archiveURL: URL) throws -> ADBTVPreparedAPKM {
        guard maximumEntryCount > 0 else {
            throw ADBTVAPKMExtractionError.invalidMaximumEntryCount(maximumEntryCount)
        }
        guard maximumUncompressedByteCount > 0 else {
            throw ADBTVAPKMExtractionError.invalidMaximumUncompressedByteCount(
                maximumUncompressedByteCount
            )
        }

        let didStartAccessing = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw ADBTVAPKMExtractionError.invalidArchive(String(describing: error))
        }

        var entries: [(entry: Entry, fileName: String)] = []
        var seenFileNames = Set<String>()
        var entryCount = 0
        var totalUncompressedByteCount: Int64 = 0

        for entry in archive {
            entryCount += 1
            guard entryCount <= maximumEntryCount else {
                throw ADBTVAPKMExtractionError.tooManyEntries(maximum: maximumEntryCount)
            }
            guard Self.isSafe(path: entry.path) else {
                throw ADBTVAPKMExtractionError.unsafeEntryPath(entry.path)
            }
            guard entry.path.lowercased().hasSuffix(".apk") else {
                continue
            }
            guard entry.type == .file else {
                throw ADBTVAPKMExtractionError.invalidAPKEntry(entry.path)
            }
            let fileName = String(entry.path.split(separator: "/").last ?? "")
            let normalizedFileName = fileName.lowercased()
            guard seenFileNames.insert(normalizedFileName).inserted else {
                throw ADBTVAPKMExtractionError.duplicateAPKFileName(fileName)
            }
            guard let byteCount = Int64(exactly: entry.uncompressedSize), byteCount > 0 else {
                throw ADBTVAPKMExtractionError.invalidAPKByteCount(
                    fileName: fileName,
                    byteCount: entry.uncompressedSize
                )
            }
            let (nextTotal, overflow) = totalUncompressedByteCount.addingReportingOverflow(byteCount)
            guard !overflow, nextTotal <= maximumUncompressedByteCount else {
                throw ADBTVAPKMExtractionError.packageTooLarge(
                    maximumByteCount: maximumUncompressedByteCount
                )
            }
            totalUncompressedByteCount = nextTotal
            entries.append((entry, fileName))
        }

        let baseEntries = entries.filter { $0.fileName.lowercased() == "base.apk" }
        guard baseEntries.count == 1 else {
            throw baseEntries.isEmpty
                ? ADBTVAPKMExtractionError.missingBaseAPK
                : ADBTVAPKMExtractionError.multipleBaseAPKs
        }
        guard entries.count > 1 else {
            throw ADBTVAPKMExtractionError.missingSplitAPKs
        }
        entries.sort {
            if $0.fileName.lowercased() == "base.apk" { return true }
            if $1.fileName.lowercased() == "base.apk" { return false }
            return $0.entry.path.localizedStandardCompare($1.entry.path) == .orderedAscending
        }

        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTV-APKM-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectoryURL,
                withIntermediateDirectories: false
            )
            var files: [ADBPackageSessionFile] = []
            for (index, item) in entries.enumerated() {
                try Task.checkCancellation()
                let destinationURL = temporaryDirectoryURL
                    .appendingPathComponent("\(index).apk", isDirectory: false)
                try extract(
                    item.entry,
                    named: item.fileName,
                    from: archive,
                    to: destinationURL
                )
                let contents = try Data(contentsOf: destinationURL, options: .mappedIfSafe)
                try ADBAPKValidator().validate(contents: Array(contents))
                files.append(try ADBPackageSessionFile(
                    fileURL: destinationURL,
                    fileName: item.fileName,
                    byteCount: Int64(item.entry.uncompressedSize)
                ))
            }
            return ADBTVPreparedAPKM(
                files: files,
                temporaryDirectoryURL: temporaryDirectoryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            throw error
        }
    }

    private func extract(
        _ entry: Entry,
        named fileName: String,
        from archive: Archive,
        to destinationURL: URL
    ) throws {
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw ADBTVAPKMExtractionError.couldNotCreateTemporaryFile(fileName)
        }
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }
        var extractedByteCount: Int64 = 0

        do {
            _ = try archive.extract(entry) { data in
                try Task.checkCancellation()
                extractedByteCount += Int64(data.count)
                guard extractedByteCount <= Int64(entry.uncompressedSize),
                      extractedByteCount <= maximumUncompressedByteCount else {
                    throw ADBTVAPKMExtractionError.entrySizeMismatch(
                        fileName: fileName,
                        expected: entry.uncompressedSize,
                        actual: extractedByteCount
                    )
                }
                try fileHandle.write(contentsOf: data)
            }
        } catch let error as ADBTVAPKMExtractionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ADBTVAPKMExtractionError.couldNotExtract(
                fileName: fileName,
                underlyingError: String(describing: error)
            )
        }

        guard extractedByteCount == Int64(entry.uncompressedSize) else {
            throw ADBTVAPKMExtractionError.entrySizeMismatch(
                fileName: fileName,
                expected: entry.uncompressedSize,
                actual: extractedByteCount
            )
        }
    }

    private static func isSafe(path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= maximumEntryPathByteCount,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.utf8.contains(0) else {
            return false
        }
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard !normalizedPath.isEmpty else {
            return false
        }
        return !normalizedPath.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.isEmpty || $0 == "." || $0 == ".."
        }
    }
}

public enum ADBTVAPKMExtractionError: Error, Equatable, Sendable {
    case invalidMaximumEntryCount(Int)
    case invalidMaximumUncompressedByteCount(Int64)
    case invalidArchive(String)
    case tooManyEntries(maximum: Int)
    case unsafeEntryPath(String)
    case invalidAPKEntry(String)
    case duplicateAPKFileName(String)
    case invalidAPKByteCount(fileName: String, byteCount: UInt64)
    case packageTooLarge(maximumByteCount: Int64)
    case missingBaseAPK
    case multipleBaseAPKs
    case missingSplitAPKs
    case couldNotCreateTemporaryFile(String)
    case couldNotExtract(fileName: String, underlyingError: String)
    case entrySizeMismatch(fileName: String, expected: UInt64, actual: Int64)
}
