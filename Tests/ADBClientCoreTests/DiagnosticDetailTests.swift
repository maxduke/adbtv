import XCTest
@testable import ADBClientCore

final class DiagnosticDetailTests: XCTestCase {
    func testFormattedDescriptionIncludesSortedContext() {
        let detail = DiagnosticDetail(
            summary: "Camera access is denied.",
            context: [
                "reason": "permissionDenied",
                "operation": "scanPairingQRCode"
            ]
        )

        XCTAssertEqual(
            detail.formattedDescription,
            """
            Camera access is denied.
            operation: scanPairingQRCode
            reason: permissionDenied
            """
        )
    }

    func testFormattedDescriptionWithNoContextIsTheSummary() {
        let detail = DiagnosticDetail(summary: "Connection refused.")

        XCTAssertEqual(detail.formattedDescription, "Connection refused.")
    }
}
