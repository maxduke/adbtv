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

    func testBrowsingDiscoverySuspendsAndResumesOnce() {
        var policy = ADBTVAutomaticDiscoveryPolicy()

        XCTAssertTrue(policy.shouldSuspendDiscovery(status: .browsing))
        XCTAssertTrue(policy.isDiscoverySuspended)
        XCTAssertTrue(policy.shouldResumeDiscovery(status: .idle))
        XCTAssertFalse(policy.isDiscoverySuspended)
        XCTAssertFalse(policy.shouldResumeDiscovery(status: .idle))
    }

    func testIdleOrFailedDiscoveryDoesNotResume() {
        var idlePolicy = ADBTVAutomaticDiscoveryPolicy()
        XCTAssertFalse(idlePolicy.shouldSuspendDiscovery(status: .idle))
        XCTAssertFalse(idlePolicy.shouldResumeDiscovery(status: .idle))

        var failedPolicy = ADBTVAutomaticDiscoveryPolicy()
        XCTAssertFalse(failedPolicy.shouldSuspendDiscovery(status: .failed(
            userMessage: "Discovery failed.",
            diagnosticDetail: DiagnosticDetail(summary: "Local network denied.")
        )))
        XCTAssertFalse(failedPolicy.shouldResumeDiscovery(status: .idle))
    }

    func testChangedStatusPreventsSuspendedDiscoveryFromResuming() {
        var policy = ADBTVAutomaticDiscoveryPolicy()
        XCTAssertTrue(policy.shouldSuspendDiscovery(status: .browsing))

        XCTAssertFalse(policy.shouldResumeDiscovery(status: .failed(
            userMessage: "Discovery failed.",
            diagnosticDetail: DiagnosticDetail(summary: "Browser failed.")
        )))
        XCTAssertFalse(policy.isDiscoverySuspended)
        XCTAssertFalse(policy.shouldResumeDiscovery(status: .idle))
    }

    func testAuthorizationFailureRetriesOnceAfterAppBecomesActive() {
        var policy = ADBTVAutomaticDiscoveryPolicy()
        let failedStatus = ADBTVDiscoveryStatus.failed(
            userMessage: "Discovery is not authorized.",
            diagnosticDetail: DiagnosticDetail(summary: "NoAuth")
        )

        policy.recordAuthorizationFailure()

        XCTAssertTrue(policy.hasPendingAuthorizationRetry)
        XCTAssertTrue(policy.shouldRetryAuthorizationFailureAfterActivation(status: failedStatus))
        XCTAssertFalse(policy.hasPendingAuthorizationRetry)
        XCTAssertFalse(policy.shouldRetryAuthorizationFailureAfterActivation(status: failedStatus))
    }

    func testAuthorizationRetryIsDiscardedWhenDiscoveryStatusChanged() {
        var policy = ADBTVAutomaticDiscoveryPolicy()
        policy.recordAuthorizationFailure()

        XCTAssertFalse(policy.shouldRetryAuthorizationFailureAfterActivation(status: .browsing))
        XCTAssertFalse(policy.hasPendingAuthorizationRetry)
    }
}
