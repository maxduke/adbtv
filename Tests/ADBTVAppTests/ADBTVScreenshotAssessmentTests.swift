import ADBClientCore
import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVScreenshotAssessmentTests: XCTestCase {
    func testBlackAndTransparentSamplesAreAdvisoryButVisibleColorIsNotBlank() {
        XCTAssertEqual(ADBTVScreenshotAssessment.assessRGBA([0, 0, 0, 255, 7, 7, 7, 255]), .appearsBlank)
        XCTAssertEqual(ADBTVScreenshotAssessment.assessRGBA([255, 255, 255, 0]), .appearsBlank)
        XCTAssertEqual(ADBTVScreenshotAssessment.assessRGBA([0, 0, 0, 255, 35, 112, 220, 255]), .content)
        XCTAssertEqual(ADBTVScreenshotAssessment.assessRGBA([]), .content)
    }

#if canImport(ImageIO)
    func testDecodesRealPNGsAndPreservesTheExactExportBytes() throws {
        for (base64, expected) in [
            (blackPNG, ADBTVScreenshotAssessment.appearsBlank),
            (colorPNG, .content),
            (transparentPNG, .appearsBlank)
        ] {
            let data = try XCTUnwrap(Data(base64Encoded: base64))
            let screenshot = try ADBTVScreenshot(pngData: data)
            XCTAssertEqual(try ADBTVScreenshotAssessment.assess(screenshot), expected)
            XCTAssertEqual(screenshot.pngData, data)
        }
    }

    func testRejectsFramedPNGWithUndecodableImageData() throws {
        var data = try XCTUnwrap(Data(base64Encoded: colorPNG))
        // Preserve chunk lengths and the complete PNG envelope, but destroy the zlib stream.
        data.replaceSubrange(41..<45, with: [0, 0, 0, 0])
        let screenshot = try ADBTVScreenshot(pngData: data)
        XCTAssertThrowsError(try ADBTVScreenshotAssessment.assess(screenshot)) {
            XCTAssertEqual($0 as? ADBTVScreenshotValidationError, .undecodableImage)
        }
    }

    func testPixelBudgetIsCheckedBeforeDecodingAnOversizedBitmap() throws {
        var data = try XCTUnwrap(Data(base64Encoded: colorPNG))
        data.replaceSubrange(16..<24, with: [0, 0, 64, 0, 0, 0, 64, 0])
        let screenshot = try ADBTVScreenshot(pngData: data)
        XCTAssertThrowsError(try ADBTVScreenshotAssessment.assess(screenshot)) {
            XCTAssertEqual($0 as? ADBTVScreenshotValidationError, .tooManyPixels)
        }
    }

    private let blackPNG = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAFElEQVR4nGNgYGD4TyEeNWDUgP8AGCaPcSyJNrgAAAAASUVORK5CYII="
    private let colorPNG = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAFklEQVR4nGNQLrjznxLMMGrAqAFADAAEGl3wf2IiSgAAAABJRU5ErkJggg=="
    private let transparentPNG = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAD0lEQVR4nGNgGAWjgAoAAAJJAAHZX3+dAAAAAElFTkSuQmCC"
#endif
}
