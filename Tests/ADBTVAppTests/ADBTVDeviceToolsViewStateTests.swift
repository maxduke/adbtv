import ADBClientCore
import XCTest
@testable import ADBTVApp

final class ADBTVDeviceToolsViewStateTests: XCTestCase {
    func testOperationStateTracksCompletionAndCancellation() {
        let deviceID = ADBTVDeviceSummary.ID()
        var state = ADBTVDeviceToolsViewState(deviceID: deviceID)

        state.start(.shell(command: "id"))
        XCTAssertEqual(state.activeOperation, .shell(command: "id"))
        XCTAssertEqual(state.submittedShellCommand, "id")
        XCTAssertEqual(state.shellStatus, .running)

        let result = ADBCheckedShellResult(
            output: ADBShellOutput(bytes: Array("uid=2000(shell)\n".utf8)),
            exitCode: 0
        )
        state.finish(.shell(result))
        XCTAssertNil(state.activeOperation)
        XCTAssertEqual(state.shellResult, result)
        XCTAssertEqual(state.submittedShellCommand, "id")
        XCTAssertEqual(state.shellStatus, .finished)

        state.start(.screenshot)
        state.cancel()
        XCTAssertNil(state.activeOperation)
        XCTAssertEqual(state.screenshotStatus, .idle)

        state.start(.cacheCleanup(desiredFreeByteCount: 1_000_000))
        XCTAssertEqual(state.cacheCleanupStatus, .running)
        state.cancel()
        XCTAssertEqual(state.cacheCleanupStatus, .idle)
    }

    func testStateDoesNotCarryResultsToAnotherDevice() {
        let firstID = ADBTVDeviceSummary.ID()
        let secondID = ADBTVDeviceSummary.ID()
        let state = ADBTVDeviceToolsViewState.preview(deviceID: firstID)

        let secondState = state.forDevice(secondID)

        XCTAssertEqual(secondState.deviceID, secondID)
        XCTAssertNil(secondState.information)
        XCTAssertNil(secondState.screenshot)
        XCTAssertNil(secondState.screenshotAssessment)
        XCTAssertNil(secondState.shellResult)
        XCTAssertNil(secondState.submittedShellCommand)
    }

    func testBlankScreenshotIsKeptForSharingAndReplacedWithTheNextSuccessfulCapture() throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAABAAAAAJCAYAAAA7KqwyAAAAFElEQVR4nGNgYGD4TyEeNWDUgP8AGCaPcSyJNrgAAAAASUVORK5CYII="))
        let screenshot = try ADBTVScreenshot(pngData: png)
        var state = ADBTVDeviceToolsViewState(deviceID: UUID())
        state.start(.screenshot)
        state.finish(.screenshot(screenshot, assessment: .appearsBlank))
        XCTAssertEqual(state.screenshot?.pngData, png)
        XCTAssertEqual(state.screenshotAssessment, .appearsBlank)
        XCTAssertEqual(state.screenshotStatus, .ready)
        state.start(.screenshot)
        state.cancel()
        XCTAssertEqual(state.screenshotAssessment, .appearsBlank)
        state.finish(.screenshot(screenshot, assessment: .content))
        XCTAssertEqual(state.screenshotAssessment, .content)
        XCTAssertNil(state.forDevice(UUID()).screenshotAssessment)
    }

    func testShellPresetsUseExpectedReadOnlyCommands() {
        XCTAssertEqual(
            ADBTVShellPreset.all.map(\.command),
            [
                "getprop",
                "ip addr show",
                "df -h",
                "pm list packages -3",
                "logcat -d -t 200"
            ]
        )
    }
}
