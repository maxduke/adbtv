import ADBClientCore
import Foundation
import XCTest
import ZIPFoundation
@testable import ADBTVApp

final class ADBTVAPKMExtractorTests: XCTestCase {
    func testExtractsAndValidatesBaseAndSplitAPKs() throws {
        let archiveURL = try makeArchive(entries: [
            ("split_config.en.apk", makeADBTVTestAPK()),
            ("base.apk", makeADBTVTestAPK()),
            ("info.json", Array("{}".utf8))
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let prepared = try ADBTVAPKMExtractor().extract(from: archiveURL)
        defer { try? prepared.removeTemporaryFiles() }

        XCTAssertEqual(prepared.files.map(\.fileName), ["base.apk", "split_config.en.apk"])
        XCTAssertTrue(prepared.files.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
    }

    func testRejectsBundleWithoutBaseAPK() throws {
        let archiveURL = try makeArchive(entries: [
            ("split_config.en.apk", makeADBTVTestAPK())
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        XCTAssertThrowsError(try ADBTVAPKMExtractor().extract(from: archiveURL)) { error in
            XCTAssertEqual(error as? ADBTVAPKMExtractionError, .missingBaseAPK)
        }
    }

    func testRejectsBundleAboveUncompressedLimit() throws {
        let apk = makeADBTVTestAPK()
        let archiveURL = try makeArchive(entries: [
            ("base.apk", apk),
            ("split_config.en.apk", apk)
        ])
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        XCTAssertThrowsError(
            try ADBTVAPKMExtractor(
                maximumUncompressedByteCount: Int64(apk.count * 2 - 1)
            ).extract(from: archiveURL)
        ) { error in
            XCTAssertEqual(
                error as? ADBTVAPKMExtractionError,
                .packageTooLarge(maximumByteCount: Int64(apk.count * 2 - 1))
            )
        }
    }

    private func makeArchive(entries: [(String, [UInt8])]) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkm")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for (index, entry) in entries.enumerated() {
            let fileURL = directoryURL.appendingPathComponent("\(index)")
            try Data(entry.1).write(to: fileURL)
            try archive.addEntry(
                with: entry.0,
                fileURL: fileURL,
                compressionMethod: .deflate
            )
        }
        return archiveURL
    }
}
