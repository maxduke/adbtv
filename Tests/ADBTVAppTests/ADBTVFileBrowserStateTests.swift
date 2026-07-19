import XCTest
@testable import ADBTVApp

final class ADBTVFileBrowserStateTests: XCTestCase {
    func testCancelledLoadReturnsToReadyState() {
        var status = ADBTVFileListStatus.loading

        status.finishCancelledLoad()

        XCTAssertEqual(status, .ready)
    }
}
