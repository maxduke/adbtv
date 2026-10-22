import Foundation
import XCTest

final class ADBTVColorContrastTests: XCTestCase {
    func testAccentTextHasContrastOnLightAndDarkSurfaces() throws {
        let catalog = try load("Apps/ADBTViOS/Assets.xcassets/AccentColor.colorset/Contents.json")
        XCTAssertTrue(catalog.colors.contains { $0.isDark })
        let light = try catalog.rgb(dark: false)
        let dark = try catalog.rgb(dark: true)
        for surface in [RGB(1, 1, 1), RGB(242 / 255.0, 242 / 255.0, 247 / 255.0)] {
            XCTAssertGreaterThanOrEqual(light.contrast(with: surface), 4.5)
        }
        for surface in [RGB(0, 0, 0), RGB(28 / 255.0, 28 / 255.0, 30 / 255.0),
                        RGB(44 / 255.0, 44 / 255.0, 46 / 255.0)] {
            XCTAssertGreaterThanOrEqual(dark.contrast(with: surface), 4.5)
        }
    }

    func testProminentActionFillSupportsWhiteLabelsInBothAppearances() throws {
        let catalog = try load(
            "Sources/ADBTVApp/Resources/Colors.xcassets/ActionColor.colorset/Contents.json"
        )
        for dark in [false, true] {
            XCTAssertGreaterThanOrEqual(try catalog.rgb(dark: dark).contrast(with: RGB(1, 1, 1)), 4.5)
        }
    }

    private func load(_ path: String) throws -> ColorCatalog {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(ColorCatalog.self, from: Data(contentsOf: root.appendingPathComponent(path)))
    }
}

private struct ColorCatalog: Decodable {
    var colors: [Entry]

    struct Entry: Decodable {
        var color: Color
        var appearances: [Appearance]?
        var isDark: Bool { appearances?.contains { $0.appearance == "luminosity" && $0.value == "dark" } == true }
    }

    struct Appearance: Decodable {
        var appearance: String
        var value: String
    }

    struct Color: Decodable {
        var components: [String: String]
    }

    func rgb(dark: Bool) throws -> RGB {
        let entry = try XCTUnwrap(
            (dark ? colors.first { $0.isDark } : nil) ?? colors.first { $0.appearances == nil }
        )
        let values = try ["red", "green", "blue", "alpha"].map {
            try XCTUnwrap(entry.color.components[$0].flatMap(Double.init))
        }
        XCTAssertEqual(values[3], 1, "Contrast tests require an opaque color.")
        return RGB(values[0], values[1], values[2])
    }
}

private struct RGB {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var luminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: RGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}
