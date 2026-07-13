import XCTest
@testable import ADBTVApp

final class ADBTVBonjourAuthorizationRetryPolicyTests: XCTestCase {
    func testRetriesAcrossBoundedAuthorizationWindow() {
        var policy = ADBTVBonjourAuthorizationRetryPolicy()

        XCTAssertEqual(policy.nextDelayInSeconds(), 1)
        XCTAssertEqual(policy.nextDelayInSeconds(), 2)
        XCTAssertEqual(policy.nextDelayInSeconds(), 4)
        XCTAssertEqual(policy.nextDelayInSeconds(), 8)
        XCTAssertEqual(policy.nextDelayInSeconds(), 15)
        XCTAssertNil(policy.nextDelayInSeconds())
        XCTAssertEqual(policy.attempt, 5)
    }

    func testResetStartsNewAuthorizationWindow() {
        var policy = ADBTVBonjourAuthorizationRetryPolicy()
        _ = policy.nextDelayInSeconds()
        _ = policy.nextDelayInSeconds()

        policy.reset()

        XCTAssertEqual(policy.attempt, 0)
        XCTAssertEqual(policy.nextDelayInSeconds(), 1)
    }
}
