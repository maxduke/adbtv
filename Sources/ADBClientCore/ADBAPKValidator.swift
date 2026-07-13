import Foundation

public struct ADBAPKValidator: Sendable {
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4b50
    private static let centralDirectoryDigitalSignature: UInt32 = 0x0505_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let endOfCentralDirectoryLength = 22
    private static let maximumZIPCommentLength = 65_535
    private static let manifestPath = Array("AndroidManifest.xml".utf8)

    public init() {}

    public func validate(contents: [UInt8]) throws {
        guard contents.count >= Self.endOfCentralDirectoryLength else {
            throw ADBAPKValidationError.fileTooSmall(contents.count)
        }

        guard contents.littleEndianUInt32(at: 0) == Self.localFileHeaderSignature else {
            throw ADBAPKValidationError.invalidZIPSignature
        }

        let endRecordOffset = try endOfCentralDirectoryOffset(in: contents)
        guard let diskNumber = contents.littleEndianUInt16(at: endRecordOffset + 4),
              let centralDirectoryDisk = contents.littleEndianUInt16(at: endRecordOffset + 6),
              let entriesOnDisk = contents.littleEndianUInt16(at: endRecordOffset + 8),
              let totalEntries = contents.littleEndianUInt16(at: endRecordOffset + 10),
              let centralDirectorySizeValue = contents.littleEndianUInt32(at: endRecordOffset + 12),
              let centralDirectoryOffsetValue = contents.littleEndianUInt32(at: endRecordOffset + 16) else {
            throw ADBAPKValidationError.invalidEndOfCentralDirectory
        }

        guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == totalEntries else {
            throw ADBAPKValidationError.multiDiskArchiveUnsupported
        }

        guard totalEntries != UInt16.max,
              centralDirectorySizeValue != UInt32.max,
              centralDirectoryOffsetValue != UInt32.max else {
            throw ADBAPKValidationError.zip64ArchiveUnsupported
        }

        let centralDirectoryOffset = Int(centralDirectoryOffsetValue)
        let centralDirectorySize = Int(centralDirectorySizeValue)
        guard contents.containsRange(
            startingAt: centralDirectoryOffset,
            length: centralDirectorySize,
            upperBound: endRecordOffset
        ) else {
            throw ADBAPKValidationError.invalidCentralDirectory
        }

        let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize
        var cursor = centralDirectoryOffset
        var containsManifest = false

        for entryIndex in 0..<Int(totalEntries) {
            guard contents.containsRange(startingAt: cursor, length: 46, upperBound: centralDirectoryEnd),
                  contents.littleEndianUInt32(at: cursor) == Self.centralDirectoryHeaderSignature,
                  let fileNameLength = contents.littleEndianUInt16(at: cursor + 28),
                  let extraFieldLength = contents.littleEndianUInt16(at: cursor + 30),
                  let commentLength = contents.littleEndianUInt16(at: cursor + 32) else {
                throw ADBAPKValidationError.invalidCentralDirectoryEntry(entryIndex)
            }

            let variableLength = Int(fileNameLength) + Int(extraFieldLength) + Int(commentLength)
            let entryLength = 46 + variableLength
            guard contents.containsRange(
                startingAt: cursor,
                length: entryLength,
                upperBound: centralDirectoryEnd
            ) else {
                throw ADBAPKValidationError.invalidCentralDirectoryEntry(entryIndex)
            }

            let fileNameStart = cursor + 46
            let fileNameEnd = fileNameStart + Int(fileNameLength)
            let fileName = Array(contents[fileNameStart..<fileNameEnd])
            if fileName == Self.manifestPath {
                try validateManifestEntry(
                    centralEntryOffset: cursor,
                    centralDirectoryOffset: centralDirectoryOffset,
                    fileName: fileName,
                    contents: contents
                )
                containsManifest = true
            }

            cursor += entryLength
        }

        try validateCentralDirectoryRemainder(
            contents: contents,
            cursor: cursor,
            centralDirectoryEnd: centralDirectoryEnd
        )

        guard containsManifest else {
            throw ADBAPKValidationError.missingAndroidManifest
        }
    }

    private func endOfCentralDirectoryOffset(in contents: [UInt8]) throws -> Int {
        let minimumOffset = max(
            0,
            contents.count - Self.endOfCentralDirectoryLength - Self.maximumZIPCommentLength
        )
        var candidate = contents.count - Self.endOfCentralDirectoryLength

        while candidate >= minimumOffset {
            if contents.littleEndianUInt32(at: candidate) == Self.endOfCentralDirectorySignature,
               let commentLength = contents.littleEndianUInt16(at: candidate + 20),
               candidate + Self.endOfCentralDirectoryLength + Int(commentLength) == contents.count {
                return candidate
            }

            candidate -= 1
        }

        throw ADBAPKValidationError.missingEndOfCentralDirectory
    }

    private func validateManifestEntry(
        centralEntryOffset: Int,
        centralDirectoryOffset: Int,
        fileName: [UInt8],
        contents: [UInt8]
    ) throws {
        guard let compressedSizeValue = contents.littleEndianUInt32(at: centralEntryOffset + 20),
              let localHeaderOffsetValue = contents.littleEndianUInt32(at: centralEntryOffset + 42) else {
            throw ADBAPKValidationError.invalidManifestEntry
        }
        guard compressedSizeValue != UInt32.max, localHeaderOffsetValue != UInt32.max else {
            throw ADBAPKValidationError.zip64ArchiveUnsupported
        }

        let localHeaderOffset = Int(localHeaderOffsetValue)
        guard contents.containsRange(
            startingAt: localHeaderOffset,
            length: 30,
            upperBound: centralDirectoryOffset
        ), contents.littleEndianUInt32(at: localHeaderOffset) == Self.localFileHeaderSignature,
           let localFileNameLength = contents.littleEndianUInt16(at: localHeaderOffset + 26),
           let localExtraFieldLength = contents.littleEndianUInt16(at: localHeaderOffset + 28) else {
            throw ADBAPKValidationError.invalidManifestEntry
        }

        let localFileNameStart = localHeaderOffset + 30
        let localFileNameEnd = localFileNameStart + Int(localFileNameLength)
        let dataStart = localFileNameEnd + Int(localExtraFieldLength)
        guard contents.containsRange(
            startingAt: localFileNameStart,
            length: Int(localFileNameLength),
            upperBound: centralDirectoryOffset
        ), Array(contents[localFileNameStart..<localFileNameEnd]) == fileName,
           contents.containsRange(
               startingAt: dataStart,
               length: Int(compressedSizeValue),
               upperBound: centralDirectoryOffset
           ) else {
            throw ADBAPKValidationError.invalidManifestEntry
        }
    }

    private func validateCentralDirectoryRemainder(
        contents: [UInt8],
        cursor: Int,
        centralDirectoryEnd: Int
    ) throws {
        guard cursor != centralDirectoryEnd else {
            return
        }

        guard contents.containsRange(startingAt: cursor, length: 6, upperBound: centralDirectoryEnd),
              contents.littleEndianUInt32(at: cursor) == Self.centralDirectoryDigitalSignature,
              let signatureDataLength = contents.littleEndianUInt16(at: cursor + 4),
              cursor + 6 + Int(signatureDataLength) == centralDirectoryEnd else {
            throw ADBAPKValidationError.invalidCentralDirectory
        }
    }
}

public enum ADBAPKValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case fileTooSmall(Int)
    case invalidZIPSignature
    case missingEndOfCentralDirectory
    case invalidEndOfCentralDirectory
    case multiDiskArchiveUnsupported
    case zip64ArchiveUnsupported
    case invalidCentralDirectory
    case invalidCentralDirectoryEntry(Int)
    case invalidManifestEntry
    case missingAndroidManifest

    public var description: String {
        switch self {
        case .fileTooSmall(let byteCount):
            return "The APK is too small to be a ZIP archive (\(byteCount) bytes)."
        case .invalidZIPSignature:
            return "The APK does not start with a ZIP local-file header."
        case .missingEndOfCentralDirectory:
            return "The APK is missing its ZIP end-of-central-directory record."
        case .invalidEndOfCentralDirectory:
            return "The APK has an invalid ZIP end-of-central-directory record."
        case .multiDiskArchiveUnsupported:
            return "Split ZIP archives are not supported as APK packages."
        case .zip64ArchiveUnsupported:
            return "ZIP64 archives are not supported as APK packages."
        case .invalidCentralDirectory:
            return "The APK has an invalid ZIP central directory."
        case .invalidCentralDirectoryEntry(let index):
            return "The APK has an invalid ZIP central-directory entry at index \(index)."
        case .invalidManifestEntry:
            return "The APK has an invalid AndroidManifest.xml ZIP entry."
        case .missingAndroidManifest:
            return "The APK does not contain AndroidManifest.xml at the archive root."
        }
    }
}

private extension Array where Element == UInt8 {
    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard containsRange(startingAt: offset, length: 2) else {
            return nil
        }

        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard containsRange(startingAt: offset, length: 4) else {
            return nil
        }

        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func containsRange(startingAt offset: Int, length: Int, upperBound: Int? = nil) -> Bool {
        let limit = upperBound ?? count
        return offset >= 0
            && length >= 0
            && limit >= 0
            && limit <= count
            && offset <= limit
            && length <= limit - offset
    }
}
