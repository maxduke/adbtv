import XCTest
@testable import ADBClientCore

final class ADBAPKValidatorTests: XCTestCase {
    func testAcceptsZIPArchiveWithRootAndroidManifest() throws {
        XCTAssertNoThrow(try ADBAPKValidator().validate(contents: makeTestAPK()))
    }

    func testRejectsNonZIPAndTruncatedArchives() throws {
        XCTAssertThrowsError(
            try ADBAPKValidator().validate(contents: Array(repeating: 0, count: 22))
        ) { error in
            XCTAssertEqual(error as? ADBAPKValidationError, .invalidZIPSignature)
        }

        let archiveWithoutEndRecord = Array(makeTestAPK().dropLast(22))
        XCTAssertThrowsError(try ADBAPKValidator().validate(contents: archiveWithoutEndRecord)) { error in
            XCTAssertEqual(error as? ADBAPKValidationError, .missingEndOfCentralDirectory)
        }
    }

    func testRejectsArchiveWithoutRootAndroidManifest() throws {
        XCTAssertThrowsError(
            try ADBAPKValidator().validate(contents: makeTestAPK(entryNames: ["classes.dex"]))
        ) { error in
            XCTAssertEqual(error as? ADBAPKValidationError, .missingAndroidManifest)
        }
    }

    func testRejectsInvalidManifestLocalFileEntry() throws {
        var archive = makeTestAPK()
        archive[30] = 0x58

        XCTAssertThrowsError(try ADBAPKValidator().validate(contents: archive)) { error in
            XCTAssertEqual(error as? ADBAPKValidationError, .invalidManifestEntry)
        }
    }

    func testRejectsMalformedCentralDirectory() throws {
        var archive = makeTestAPK()
        let endRecordOffset = archive.count - 22
        let centralDirectoryOffset = Int(archive.testUInt32(at: endRecordOffset + 16))
        archive[centralDirectoryOffset] = 0

        XCTAssertThrowsError(try ADBAPKValidator().validate(contents: archive)) { error in
            XCTAssertEqual(error as? ADBAPKValidationError, .invalidCentralDirectoryEntry(0))
        }
    }

    func testRejectsMultiDiskAndZIP64Archives() throws {
        var multiDiskArchive = makeTestAPK()
        let multiDiskEndOffset = multiDiskArchive.count - 22
        multiDiskArchive[multiDiskEndOffset + 4] = 1
        XCTAssertThrowsError(try ADBAPKValidator().validate(contents: multiDiskArchive)) { error in
            XCTAssertEqual(error as? ADBAPKValidationError, .multiDiskArchiveUnsupported)
        }

        var zip64Archive = makeTestAPK()
        let zip64EndOffset = zip64Archive.count - 22
        zip64Archive[zip64EndOffset + 8] = 0xff
        zip64Archive[zip64EndOffset + 9] = 0xff
        zip64Archive[zip64EndOffset + 10] = 0xff
        zip64Archive[zip64EndOffset + 11] = 0xff
        XCTAssertThrowsError(try ADBAPKValidator().validate(contents: zip64Archive)) { error in
            XCTAssertEqual(error as? ADBAPKValidationError, .zip64ArchiveUnsupported)
        }
    }

    func testValidationErrorsHaveTechnicalDescriptions() {
        XCTAssertEqual(
            String(describing: ADBAPKValidationError.missingAndroidManifest),
            "The APK does not contain AndroidManifest.xml at the archive root."
        )
    }
}
