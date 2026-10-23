import Foundation
import XCTest
@testable import ADBTVApp

final class ADBTVLocalizationTests: XCTestCase {
    func testEnglishAndChineseResourcesHaveMatchingSafeFormats() throws {
        let english = try table("en")
        let chinese = try table("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for (key, value) in english {
            XCTAssertEqual(key, value, "English fallback should preserve the source text.")
            let translation = try XCTUnwrap(chinese[key])
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertEqual(try placeholders(value), try placeholders(translation), key)
        }
    }

    func testChineseLookupAndFormattingPreserveExternalValues() throws {
        let chinese = try languageBundle("zh-Hans")
        let english = try languageBundle("en")
        XCTAssertEqual(adbTVLocalized("Files", bundle: chinese), "文件")
        XCTAssertEqual(adbTVLocalized("Search This Folder", bundle: chinese), "搜索此文件夹")
        XCTAssertEqual(adbTVLocalized("Newest First", bundle: chinese), "修改时间从新到旧")
        XCTAssertEqual(adbTVLocalized("Files", bundle: english), "Files")
        XCTAssertEqual(adbTVLocalized("untranslated.key", bundle: chinese), "untranslated.key")

        let appName = "电影 100% %@"
        let package = "com.example.player"
        XCTAssertEqual(
            adbTVLocalized("This removes %@ and its app data for the current TV user.\n\n%@",
                           appName, package, bundle: chinese),
            "这将为当前电视用户卸载 \(appName)，并删除其应用数据。\n\n\(package)"
        )
        let fileName = "Café_电影%20.apk"
        XCTAssertEqual(adbTVLocalized("Actions for %@", fileName, bundle: chinese), "\(fileName) 的操作")
        XCTAssertEqual(adbTVLocalized("Actions for %@", fileName, bundle: english), "Actions for \(fileName)")
    }

    func testEveryLiteralLookupHasTranslations() throws {
        let english = try table("en")
        let appSources = packageRoot.appendingPathComponent("Sources/ADBTVApp")
        let pattern = try NSRegularExpression(pattern: #"adbTVLocalized\(("(?:\\.|[^"\\])*")"#)
        var keys = Set<String>()
        for url in try FileManager.default.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
            where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: source))
                let data = Data(source[range].utf8)
                let key = try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String)
                keys.insert(key)
                XCTAssertNotNil(english[key], "\(url.lastPathComponent): \(key)")
            }
        }
        XCTAssertFalse(keys.isEmpty)
    }

    func testPermissionDescriptionsAreLocalizedAndBundledByXcode() throws {
        let keys = ["NSCameraUsageDescription", "NSLocalNetworkUsageDescription",
                    "NSPhotoLibraryAddUsageDescription", "Android application package"]
        let app = packageRoot.appendingPathComponent("Apps/ADBTViOS")
        var translations = [[String: String]]()
        for language in ["en", "zh-Hans"] {
            let url = app.appendingPathComponent("\(language).lproj/InfoPlist.strings")
            let value = try propertyList(at: url)
            for key in keys { XCTAssertFalse(try XCTUnwrap(value[key]).isEmpty) }
            translations.append(value)
        }
        for key in keys { XCTAssertNotEqual(translations[0][key], translations[1][key]) }
        let info = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        let metadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])
        XCTAssertEqual(metadata["CFBundleLocalizations"] as? [String], ["en", "zh-Hans"])
        let project = try String(contentsOf: packageRoot.appendingPathComponent("ADBTV.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(project.contains("InfoPlist.strings in Resources"))
        XCTAssertTrue(project.contains("zh-Hans.lproj/InfoPlist.strings"))
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let localization = try XCTUnwrap(adbTVLocalizationBundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let path = try XCTUnwrap(adbTVLocalizationBundle.path(forResource: localization, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func table(_ language: String) throws -> [String: String] {
        let bundle = try languageBundle(language)
        return try propertyList(at: XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings")))
    }

    private func propertyList(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private func placeholders(_ value: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: "%@|%%")
        let range = NSRange(value.startIndex..., in: value)
        let remaining = expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        XCTAssertFalse(remaining.contains("%"), "Unsupported format in \(value)")
        return expression.matches(in: value, range: range).map { match in
            String(value[Range(match.range, in: value)!])
        }
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
