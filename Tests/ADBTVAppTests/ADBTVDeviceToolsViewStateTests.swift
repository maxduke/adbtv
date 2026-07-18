import ADBClientCore
import XCTest
@testable import ADBTVApp

final class ADBTVDeviceToolsViewStateTests: XCTestCase {
    func testOperationStateTracksCompletionAndCancellation() {
        let deviceID = ADBTVDeviceSummary.ID()
        var state = ADBTVDeviceToolsViewState(deviceID: deviceID)

        state.start(.shell(command: "id"))
        XCTAssertEqual(state.activeOperation, .shell(command: "id"))
        XCTAssertEqual(state.shellStatus, .running)

        let result = ADBCheckedShellResult(
            output: ADBShellOutput(bytes: Array("uid=2000(shell)\n".utf8)),
            exitCode: 0
        )
        state.finish(.shell(result))
        XCTAssertNil(state.activeOperation)
        XCTAssertEqual(state.shellResult, result)
        XCTAssertEqual(state.shellStatus, .finished)

        state.start(.screenshot)
        state.cancel()
        XCTAssertNil(state.activeOperation)
        XCTAssertEqual(state.screenshotStatus, .idle)
    }

    func testStateDoesNotCarryResultsToAnotherDevice() {
        let firstID = ADBTVDeviceSummary.ID()
        let secondID = ADBTVDeviceSummary.ID()
        let state = ADBTVDeviceToolsViewState.preview(deviceID: firstID)

        let secondState = state.forDevice(secondID)

        XCTAssertEqual(secondState.deviceID, secondID)
        XCTAssertNil(secondState.information)
        XCTAssertNil(secondState.screenshot)
        XCTAssertNil(secondState.shellResult)
    }
}
