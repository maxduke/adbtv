import ADBClientCore
import XCTest
@testable import ADBTVApp

final class ADBTVAutomaticDiscoveryPolicyTests: XCTestCase {
    func testIdleLaunchStartsDiscoveryOnlyOnce() {
        var policy = ADBTVAutomaticDiscoveryPolicy()

        XCTAssertTrue(policy.shouldStartDiscovery(status: .idle))
        XCTAssertFalse(policy.shouldStartDiscovery(status: .idle))
        XCTAssertTrue(policy.hasEvaluatedLaunch)
    }

    func testExistingDiscoveryStateDoesNotRestartAtLaunch() {
        var browsingPolicy = ADBTVAutomaticDiscoveryPolicy()
        XCTAssertFalse(browsingPolicy.shouldStartDiscovery(status: .browsing))
        XCTAssertFalse(browsingPolicy.shouldStartDiscovery(status: .idle))

        var failedPolicy = ADBTVAutomaticDiscoveryPolicy()
        XCTAssertFalse(failedPolicy.shouldStartDiscovery(status: .failed(
            userMessage: "Discovery failed.",
            diagnosticDetail: DiagnosticDetail(summary: "NoAuth")
        )))
        XCTAssertFalse(failedPolicy.shouldStartDiscovery(status: .idle))
    }
}
